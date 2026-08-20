#!/usr/bin/env python3
"""Valide les Custom Resources rendus contre les VRAIES CRD upstream.

Deux niveaux, et le second est celui qui compte :

  1. schéma OpenAPI  — types, champs obligatoires, et surtout champs INCONNUS
     (l'API server les élaguerait silencieusement : une faute de frappe dans un
     nom de champ ne produit aucune erreur, juste un réglage qui n'est jamais
     appliqué).

  2. règles CEL (x-kubernetes-validations) — les invariants métier que les CRD
     déclarent. C'est ce que fait l'API server à l'admission, et c'est
     invisible pour un simple validateur de schéma comme kubeconform.
     Exemple vécu :
       the 'traffic' field can only target a Gateway, ListenerSet, GRPCRoute,
       HTTPRoute, or InferencePool

Usage :
    pip install pyyaml jsonschema cel-python
    python3 hack/validate-crs.py <dossier kustomize> [...]
"""
import glob, os, subprocess, sys, urllib.request
import yaml
from jsonschema import Draft4Validator

try:
    import celpy
except ImportError:
    celpy = None

CACHE = os.path.join(os.path.dirname(__file__), ".crd-cache")

# Les versions DOIVENT rester alignées sur celles des Application.
GW = "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/experimental"
KC = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.1/kubernetes"
AG = "https://raw.githubusercontent.com/agentgateway/agentgateway/v1.4.1/controller/install/helm/agentgateway-crds/templates"
AR = "https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.0/manifests/crds"
# Prometheus Operator. La version DOIT rester alignée sur le chart
# prometheus-operator-crds (31.0.1 -> appVersion v0.93.1) de
# clusters/<cluster>/platform/05-prometheus-operator-crds.yaml.
PO = "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.93.1/example/prometheus-operator-crd"

SOURCES = [
    f"{GW}/gateway.networking.k8s.io_gateways.yaml",
    f"{GW}/gateway.networking.k8s.io_httproutes.yaml",
    f"{GW}/gateway.networking.k8s.io_grpcroutes.yaml",
    f"{GW}/gateway.networking.k8s.io_referencegrants.yaml",
    f"{KC}/keycloaks.k8s.keycloak.org-v1.yml",
    f"{KC}/keycloakrealmimports.k8s.keycloak.org-v1.yml",
    f"{AG}/agentgateway.dev_agentgatewaybackends.yaml",
    f"{AG}/agentgateway.dev_agentgatewaypolicies.yaml",
    f"{AG}/agentgateway.dev_agentgatewayparameters.yaml",
    f"{AG}/agentgateway.dev_agentgatewaymodels.yaml",
    f"{AR}/application-crd.yaml",
    f"{AR}/applicationset-crd.yaml",
    f"{AR}/appproject-crd.yaml",
    "https://raw.githubusercontent.com/external-secrets/external-secrets/v2.8.0/deploy/crds/bundle.yaml",
    f"{PO}/monitoring.coreos.com_servicemonitors.yaml",
    f"{PO}/monitoring.coreos.com_podmonitors.yaml",
    f"{PO}/monitoring.coreos.com_prometheusrules.yaml",
]


def fetch():
    os.makedirs(CACHE, exist_ok=True)
    for url in SOURCES:
        dest = os.path.join(CACHE, url.rsplit("/", 1)[-1])
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            continue
        print(f"  téléchargement {url.rsplit('/', 1)[-1]}", file=sys.stderr)
        urllib.request.urlretrieve(url, dest)


def load_schemas():
    out = {}
    for f in glob.glob(os.path.join(CACHE, "*.y*ml")):
        with open(f) as fh:
            for doc in yaml.safe_load_all(fh):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                g, kind = doc["spec"]["group"], doc["spec"]["names"]["kind"]
                for v in doc["spec"]["versions"]:
                    s = v.get("schema", {}).get("openAPIV3Schema")
                    if s:
                        out[(g, v["name"], kind)] = s
    return out


def strict(node):
    """Retire les extensions x-kubernetes-* et simule l'élagage des champs
    inconnus en posant additionalProperties: false."""
    if isinstance(node, dict):
        preserve = node.get("x-kubernetes-preserve-unknown-fields", False)
        out = {k: strict(v) for k, v in node.items()
               if not k.startswith("x-kubernetes-")
               and not (k == "format" and v == "int-or-string")}
        if "properties" in out and not preserve and "additionalProperties" not in out:
            out["additionalProperties"] = False
        return out
    if isinstance(node, list):
        return [strict(x) for x in node]
    return node


def cel_rules(node, path=()):
    out = []
    if not isinstance(node, dict):
        return out
    if node.get("x-kubernetes-validations"):
        out.append((path, node["x-kubernetes-validations"]))
    for name, sub in (node.get("properties") or {}).items():
        out += cel_rules(sub, path + (name,))
    if "items" in node:
        out += cel_rules(node["items"], path + ("[]",))
    return out


def resolve(doc, path):
    cur = [doc]
    for seg in path:
        nxt = []
        for c in cur:
            if seg == "[]" and isinstance(c, list):
                nxt += c
            elif isinstance(c, dict) and seg in c:
                nxt.append(c[seg])
        cur = nxt
    return cur


def main(dirs):
    fetch()
    schemas = load_schemas()
    env = celpy.Environment() if celpy else None
    if env is None:
        print("!! cel-python absent : les règles CEL ne seront PAS évaluées",
              file=sys.stderr)

    n_schema = n_cel = 0
    problems = []

    for d in dirs:
        r = subprocess.run(["kustomize", "build", d], capture_output=True, text=True)
        if r.returncode:
            problems.append(f"{d} :: kustomize build a échoué :: {r.stderr.strip()[:200]}")
            continue
        for doc in yaml.safe_load_all(r.stdout):
            if not doc:
                continue
            g, _, v = doc.get("apiVersion", "").rpartition("/")
            sch = schemas.get((g, v, doc["kind"]))
            if not sch:
                continue
            ident = f"{doc['kind']}/{doc['metadata']['name']}"

            root = strict(sch)
            # apiVersion/kind/metadata ne sont pas déclarés par les CRD :
            # l'élagage strict ne s'applique qu'à partir de spec.
            root.pop("additionalProperties", None)
            n_schema += 1
            for e in sorted(Draft4Validator(root).iter_errors(doc),
                            key=lambda e: list(e.path)):
                loc = "/".join(str(p) for p in e.path) or "(racine)"
                problems.append(f"{d} :: {ident} :: {loc} :: {e.message[:200]}")

            if env is None:
                continue
            for path, rules in cel_rules(sch):
                for target in resolve(doc, path):
                    cel_target = celpy.json_to_cel(target)
                    for rule in rules:
                        try:
                            prog = env.program(env.compile(rule["rule"]))
                            ok = prog.evaluate({"self": cel_target})
                        except Exception:
                            continue  # extension CEL propre à Kubernetes
                        n_cel += 1
                        if ok is not True and bool(ok) is False:
                            loc = "/".join(path) or "(racine)"
                            problems.append(
                                f"{d} :: {ident} :: {loc} :: "
                                f"{rule.get('message', rule['rule'])}")

    print(f"CR validés sur schéma : {n_schema}")
    print(f"règles CEL évaluées   : {n_cel}")
    print(f"violations            : {len(problems)}")
    for p in problems:
        print("  ✗", p)
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
