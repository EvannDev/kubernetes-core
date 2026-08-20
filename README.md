# kubernetes-core

Socle GitOps commun à tous les clusters : **Cilium**, **AgentGateway**, **Argo CD
auto-géré**, **Keycloak** et **External Secrets Operator**.

Le dépôt sert aussi de support au Lunch & Learn « gouvernance de l'IA avec
AgentGateway » : la démo finale est un serveur MCP dont l'accès **outil par
outil** est décidé par un JWT Keycloak et une expression déclarée dans Git.

---

## Démarrage rapide

```bash
make up            # les 6 étapes d'amorçage, dans l'ordre
make status        # avancement des Applications, dans l'ordre des waves
make adopt-check   # les composants amorcés sont-ils bien adoptés sans écart ?
make urls          # vérifie la Gateway et affiche les URLs
```

- Argo CD : <https://argocd.evann-deb.fr>
- Keycloak : <https://idp.evann-deb.fr>
- Open WebUI : <https://openwebui.evann-deb.fr>
- Hubble : <https://hubble.evann-deb.fr>
- Gateway IA : `make port-forward-ai` → `localhost:8081`

Aucun `port-forward` pour les quatre premières : elles sont publiées par
**Pangolin**, qui termine le TLS et achemine le trafic par le tunnel Newt
(`clusters/lab/platform/78-pangolin.yaml`). Le tunnel étant **sortant**, le pod
`newt` joint la Gateway de plateforme par son ClusterIP,
`cilium-gateway-platform.platform-gateway.svc.cluster.local:80`, comme
n'importe quel pod du cluster. Rien n'est exposé sur le nœud, rien n'est publié
vers l'hôte. Détail et raisons dans [ARCHITECTURE.md](ARCHITECTURE.md) §8.1.

### L'amorçage ne peut pas être du GitOps

Argo CD est un pod ; un pod a besoin d'un CNI ; et Cilium, configuré avec
`gatewayAPI.enabled: true`, a besoin des CRD Gateway API. Tant que Cilium n'est
pas là, le nœud est `NotReady` et **rien** ne peut être ordonnancé — y compris
Argo CD. Il y a donc forcément une amorce impérative. L'objectif n'est pas de la
supprimer mais de la rendre **courte, idempotente et identique à Git** :

| # | Cible | Ce qui se passe |
|---|---|---|
| 1 | `kind-up` | Cluster nu, sans CNI ni kube-proxy. `NotReady` : c'est attendu. |
| 2 | `install-gateway-api` | CRD Gateway API `v1.6.1`, **canal experimental**, en `--server-side`. |
| 3 | `install-cilium` | Chart `1.19.6` avec `base/cilium/values.yaml` + `clusters/lab/values/cilium.yaml`. Le nœud passe `Ready`. |
| 4 | `seed-secrets` | Les secrets sources du coffre (jamais dans Git). |
| 5 | `install-argocd` | Chart `10.3.0` avec les mêmes fichiers de valeurs que Git. |
| 6 | `bootstrap` | `kubectl apply -k bootstrap/` — le seul `kubectl` du projet. |

Chaque étape utilise **exactement** la même source et les mêmes fichiers de
valeurs que l'`Application` correspondante. Argo CD **adopte** ensuite ces trois
composants (waves -20, -10 et 5) sans rien changer : `make adopt-check` doit
afficher `Synced / Healthy`. Un `OutOfSync` signale un écart entre l'amorce et
Git — c'est précisément le genre de dérive que ce dépôt existe pour rendre
visible.

Les versions d'amorçage sont en haut du `Makefile` (`GATEWAY_API`,
`CILIUM_CHART`, `ARGOCD_CHART`) et doivent rester alignées sur celles des
`Application`.

Comptes de démo du realm `platform` : `alice` / `alice` (groupe
`platform-admins`, admin Argo CD) et `bob` / `bob` (`platform-viewers`, lecture
seule). Le compte `admin` local d'Argo CD reste disponible comme issue de
secours : `make admin-password`.

Démo AgentGateway :

```bash
make port-forward-ai        # dans un autre terminal
make demo-mcp               # avec un JWT alice  -> la liste des outils
make demo-mcp-anonymous     # sans token         -> refusé
USER_NAME=bob USER_PASS=bob make demo-mcp   # autre identité, autres droits
make models-catalog         # le catalogue de modèles, filtré par l'appelant
```

### Démo : des modèles locaux dans le même catalogue

Ollama tourne **sur le Mac**, pas dans kind : Docker Desktop ne passe pas le GPU,
et l'accélération Metal n'existe que côté hôte. La passerelle le joint par
`host.docker.internal` — le flux part du cluster vers l'hôte, donc rien à
publier et aucun `extraPortMappings` à remettre dans `kind-cluster.yaml`.

```bash
make ollama-models          # tire qwen3:8b et llama3.2:3b
make ollama-serve           # OLLAMA_HOST=0.0.0.0, bloquant, dans un terminal à part
make ollama-check           # joignabilité DEPUIS le cluster : le seul test qui compte
```

Puis, `make port-forward-ai` étant lancé :

```bash
make models-catalog                          # le catalogue vu par alice : 6 modèles
USER_NAME=bob USER_PASS=bob make models-catalog   # bob : pas de gpt-4o, mais les locaux
make demo-llm-local                          # bob discute avec un modèle local
```

Le contraste est tout l'intérêt : les modèles OpenAI sont facturés et réservés à
`platform-admins`, les modèles locaux ne coûtent rien et sont ouverts à tout
porteur d'un JWT valide. La règle se pose **par modèle**
(`base/agentgateway/models-ollama.yaml`), pas par fournisseur.

À savoir : Ollama est le seul composant hors GitOps du lab. Si `ollama serve`
n'est pas lancé, les modèles restent listés dans `/v1/models` mais l'inférence
échoue.

### Démo : un chat d'entreprise gouverné

<https://openwebui.evann-deb.fr> — Open WebUI, connecté à Keycloak en
SSO, et dont **le seul fournisseur de modèles est la Gateway IA**.

Ce qui rend la démo intéressante tient en un réglage : la connexion est en
`auth_type: system_oauth`. Open WebUI **retransmet l'access token OAuth de
l'utilisateur connecté** vers l'endpoint LLM. La passerelle voit donc l'identité
réelle de la personne devant l'écran, pas une clé de service partagée — et
`alice` obtient une réponse là où `bob` se fait refuser.

Trois pièges désamorcés dans la configuration, tous invisibles sinon :

- `ENABLE_FORWARD_OAUTH_TOKEN` **n'existe pas** ; la PR qui la proposait a été
  refusée. Le vrai mécanisme est `auth_type` **par connexion**, réglable en
  déclaratif via `OPENAI_API_CONFIGS` (objet JSON indexé par URL).
- Le token transmis est émis pour le client OIDC **d'Open WebUI**. Sans le
  client scope `agentgateway-audience`, son `aud` ne vaut pas `agentgateway` et
  la passerelle le rejette — légitimement, et de façon parfaitement obscure.
- `ENABLE_PERSISTENT_CONFIG=false`, sinon Open WebUI ne lit les variables
  d'environnement qu'au premier démarrage puis les recopie en base : Git et le
  cluster divergeraient en silence.

### Démo : un agent de code réellement gouverné

`opencode.jsonc` à la racine configure [opencode](https://opencode.ai) pour que
**tout** passe par AgentGateway — les appels LLM comme les appels d'outils MCP.
L'agent ne détient aucune clé de fournisseur : il détient une identité.

```bash
make port-forward-ai                 # Gateway IA sur localhost:8081
export AGW_TOKEN=$(make -s token)    # JWT alice, pour la route LLM
opencode mcp auth website-fetcher    # flux OAuth PKCE dans le navigateur
opencode
```

Deux modes d'authentification, et c'est volontaire :

- **MCP → OAuth complet.** opencode interroge
  `/.well-known/oauth-protected-resource`, que la passerelle sert elle-même,
  y découvre Keycloak et déroule un flux PKCE. Aucun secret sur le poste, et
  les jetons se rafraîchissent tout seuls. L'enregistrement dynamique de client
  (RFC 7591) est court-circuité par `mcp.clientId` : le client `opencode` reste
  déclaré dans Git et revu en pull request.
- **LLM → JWT en variable d'environnement.** Le SDK d'opencode n'a pas de flux
  OAuth pour les providers ; il envoie `apiKey` en `Authorization: Bearer`. On
  y met donc un JWT plutôt qu'une clé OpenAI.

Ce qu'on montre sur scène : `alice` (groupe `platform-admins`) obtient une
réponse ; `bob` se fait refuser l'outil MCP par une expression CEL versionnée ;
et dans les deux cas la clé OpenAI n'a jamais quitté le cluster.

Sans cluster sous la main, tout est vérifiable hors ligne :

```bash
make validate   # rend tous les kustomize build
make waves      # affiche l'ordre de déploiement réel
```

---

## Arborescence

```
bootstrap/                 le seul kubectl du projet, puis auto-géré
├── root.yaml              Application "root" -> pointe sur bootstrap/ (elle-même)
├── applicationset-clusters.yaml   découvre clusters/*/cluster.yaml
└── kustomization.yaml     agrège projects/ + root + l'ApplicationSet

projects/                  AppProjects = frontières de gouvernance
├── platform.yaml          plan de contrôle GitOps + Argo CD
├── network.yaml           CNI, CRD Gateway API, routage de plateforme
├── identity.yaml          External Secrets + Keycloak
├── gateway.yaml           AgentGateway
└── apps.yaml              charges de travail (droits volontairement étroits)

base/                      briques réutilisables, AUCUNE valeur propre à un cluster
├── cilium/values.yaml
├── argocd/values.yaml
├── external-secrets/      values + ClusterSecretStore + RBAC
├── keycloak/              Postgres, CR Keycloak, realm, HTTPRoute
├── platform-gateway/      Gateway classe cilium + HTTPRoute Argo CD
└── agentgateway/          values + Gateway IA + backend LLM + policies

clusters/
└── lab/
    ├── cluster.yaml       fiche d'identité (lue par l'ApplicationSet)
    ├── platform/          app-of-apps : 1 Application par composant, sync-waves
    ├── values/            valeurs Helm propres au cluster
    ├── keycloak/          overlay Kustomize : URLs réelles
    ├── platform-gateway/  overlay Kustomize : hostnames réels
    ├── agentgateway/      overlay Kustomize : issuer réel
    └── external-secrets/  overlay Kustomize : provider du coffre

apps/
└── mcp-website-fetcher/   serveur MCP de démo + RBAC outil par outil
```

**Ajouter un cluster** : copier `clusters/lab/` en `clusters/<nom>/`, ajuster
`cluster.yaml`, les `values/` et les overlays. Aucun fichier de `bootstrap/` ni
de `base/` à modifier — l'ApplicationSet découvre le nouveau dossier tout seul.

**Ajouter un composant de plateforme** : une brique dans `base/<composant>/`, une
Application dans `clusters/<cluster>/platform/` avec la bonne sync-wave.

**Ajouter une application** : un dossier dans `apps/`. L'ApplicationSet `apps-lab`
le déploie dans le projet `apps`.

---

## Ordre de déploiement

L'ordre n'est pas cosmétique : c'est ce qui rend le bootstrap reproductible.

| Wave | Composant | Pourquoi à cette place |
|-----:|-----------|------------------------|
| -20 | `gateway-api` | Propriétaire unique des CRD Gateway API. Ni Cilium ni AgentGateway ne les installent. |
| -10 | `cilium` | Le cluster est `NotReady` avant. Fournit la GatewayClass `cilium`. |
|  -8 | `cluster-dns` | Réécriture CoreDNS de l'issuer OIDC vers le Service interne de Keycloak. Doit précéder Argo CD. |
|  -5 | `external-secrets` | Les CRD `ExternalSecret` doivent exister avant les composants qui en consomment. |
|   0 | `external-secrets-config` | `ClusterSecretStore` + RBAC de lecture du coffre. |
|   5 | `argocd` | Argo CD reprend la main sur lui-même. |
|  10 | `keycloak-operator` | CRD + opérateur. |
|  15 | `keycloak` | Postgres, instance, realm `platform`. |
|  20 | `agentgateway-crds` | Groupe d'API `agentgateway.dev/v1alpha1`. |
|  25 | `agentgateway` | Plan de contrôle ; crée la GatewayClass `agentgateway`. |
|  30 | `agentgateway-config` | Gateway IA, backend LLM, policies de gouvernance. |
|  40 | `platform-gateway` | Gateway `cilium` + HTTPRoute Argo CD / Keycloak. |
|  50 | `apps-lab` | Passage de main aux équipes applicatives. |

`make waves` régénère ce tableau depuis les manifests.

---

## Versions épinglées

| Composant | Version | Source |
|---|---|---|
| Gateway API | `v1.6.1` **canal experimental** | `github.com/kubernetes-sigs/gateway-api` — `config/crd/experimental` |
| Cilium | `1.19.6` | `quay.io/cilium/charts` (OCI) |
| External Secrets Operator | `2.8.0` | `charts.external-secrets.io` |
| Argo CD (chart) | `10.3.0` | `argoproj.github.io/argo-helm` |
| Keycloak (opérateur) | `26.7.1` | `github.com/keycloak/keycloak-k8s-resources` — `kubernetes` |
| AgentGateway | `v1.4.1` | `cr.agentgateway.dev/charts` (OCI) |

Rien n'est en `latest`, ni en `stable`, ni en `main`. Un `git log` doit suffire à
expliquer pourquoi le cluster a changé.

---

## Les pièges déjà désamorcés

Ils sont documentés en commentaire à l'endroit exact où ils s'appliquent.

- **`ServerSideApply=true`** sur `gateway-api`, `keycloak-operator`, `argocd` et
  `agentgateway-crds` : ces CRD dépassent la limite de 262 kB de l'annotation
  `last-applied-configuration` du client-side apply.
- **External Secrets 2.x ne sert plus `v1beta1`** : tout manifeste
  `external-secrets.io/v1beta1` est rejeté par l'API server.
- **CR Keycloak en `v2beta1`** (version de stockage depuis 26.6.0), `spec.hostname`
  est un objet, le champ est `spec.hostname.strict`, et `spec.proxy.headers` a
  remplacé l'ancien mode proxy.
- **`configs.cm.url` du chart argo-cd** est un preset forcé en `https://` : il
  faut l'écraser pour un lab en HTTP, sinon la redirection OIDC casse.
- **`KeycloakRealmImport` ne met jamais à jour un realm existant.** Éditer le
  realm dans Git et synchroniser est un no-op.
- **Les GatewayClass ne sont pas dans Git** : les contrôleurs Cilium et
  AgentGateway les créent et les possèdent. Les déclarer provoquerait une boucle
  `prune` / `selfHeal`.
- **Gateway API : canal experimental obligatoire**, pas standard. Cilium 1.19
  indexe `TLSRoute` en `v1alpha2`, que le canal standard de v1.6 ne sert plus
  (`served: false`) — le `cilium-operator` plante alors au démarrage sur
  `no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"`.
- **L'issuer OIDC doit résoudre depuis le navigateur ET depuis les pods.**
  Avec l'ancien `keycloak.127.0.0.1.nip.io`, le nom pointait sur `127.0.0.1`,
  ce qui, dans le pod `argocd-server`, désignait le pod lui-même : Argo CD
  s'interrogeait alors lui-même et recevait son propre 404 gzippé. D'où la
  réécriture CoreDNS d'alors. Sous `idp.evann-deb.fr`, le nom résout partout
  pareil et la réécriture a été retirée — au prix d'un backchannel qui sort sur
  Internet et revient par le tunnel (§6.1).

Le détail des décisions d'architecture, et ce qui a été délibérément écarté, est
dans [ARCHITECTURE.md](ARCHITECTURE.md).
