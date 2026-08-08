SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER        ?= lab
REPO_URL       ?= https://github.com/EvannDev/kubernetes-core.git
# Ces trois versions DOIVENT rester alignées sur celles des Applications
# (clusters/<cluster>/platform/) : l'amorçage et la réconciliation doivent
# produire le même artefact.
GATEWAY_API    ?= v1.6.1
CILIUM_CHART   ?= 1.19.6
ARGOCD_CHART   ?= 10.3.0
KC_HOST        ?= keycloak.127.0.0.1.nip.io:8080
ARGOCD_HOST    ?= argocd.127.0.0.1.nip.io:8080
HUBBLE_HOST    ?= hubble.127.0.0.1.nip.io:8080

##@ Général

help: ## Affiche cette aide
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Validation (aucun cluster requis)

validate: ## Rend tous les kustomize build et vérifie que le YAML est valide
	@set -e; \
	for d in bootstrap projects clusters/$(CLUSTER)/platform \
	         base/external-secrets base/keycloak base/platform-gateway base/agentgateway \
	         clusters/$(CLUSTER)/cluster-dns \
	         clusters/$(CLUSTER)/external-secrets clusters/$(CLUSTER)/keycloak \
	         clusters/$(CLUSTER)/platform-gateway clusters/$(CLUSTER)/agentgateway \
	         apps/mcp-website-fetcher; do \
	  printf '%-45s' "kustomize build $$d"; \
	  kustomize build $$d > /dev/null && echo OK; \
	done

waves: ## Affiche l'ordre de déploiement effectif de l'app-of-apps
	@kustomize build clusters/$(CLUSTER)/platform | python3 -c "import sys,yaml; \
rows=[(int(d['metadata'].get('annotations',{}).get('argocd.argoproj.io/sync-wave',0)), d['kind'], d['metadata']['name'], d['spec'].get('project','-')) \
for d in yaml.safe_load_all(sys.stdin) if d]; \
[print(f'{w:>4}  {k:<15} {n:<24} project={p}') for w,k,n,p in sorted(rows)]"

##@ Amorçage (impératif, idempotent, puis adopté par Argo CD)

# GitOps ne peut pas s'amorcer lui-même : Argo CD est un pod, un pod a besoin
# d'un CNI, et le CNI a besoin des CRD Gateway API. La séquence ci-dessous est
# le SEUL impératif du projet. Chaque étape utilise exactement la même source et
# les mêmes valeurs que Git, pour que l'adoption par Argo CD soit un no-op.
#
#   1. kind-up             cluster nu : NotReady, aucun pod ne peut démarrer
#   2. install-gateway-api CRD partagées (prérequis de gatewayAPI.enabled)
#   3. install-cilium      le nœud passe Ready
#   4. seed-secrets        les secrets sources du coffre
#   5. install-argocd      Argo CD peut enfin être ordonnancé
#   6. bootstrap           Argo CD reprend tout, y compris les étapes 2, 3 et 5

kind-up: ## 1. Crée le cluster kind (sans CNI, sans kube-proxy)
	kind create cluster --config kind-cluster.yaml
	@echo ">> Cluster NotReady tant que Cilium n'est pas là : c'est attendu."

install-gateway-api: ## 2. CRD Gateway API (canal EXPERIMENTAL, requis par Cilium 1.19)
	# experimental et non standard : le contrôleur Gateway API de Cilium 1.19
	# indexe TLSRoute en v1alpha2, que le canal standard de v1.6 ne sert plus.
	# Doit rester identique au `path` de l'Application gateway-api.
	kubectl apply --server-side --force-conflicts \
	  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API)/experimental-install.yaml

install-cilium: install-gateway-api ## 3. Amorce Cilium (adopté ensuite par l'app cilium, wave -10)
	helm repo add cilium https://helm.cilium.io >/dev/null
	helm repo update cilium >/dev/null
	helm upgrade --install cilium cilium/cilium \
	  --version $(CILIUM_CHART) \
	  --namespace kube-system \
	  -f base/cilium/values.yaml \
	  -f clusters/$(CLUSTER)/values/cilium.yaml \
	  --wait
	kubectl wait --for=condition=Ready node --all --timeout=180s
	@echo ">> Nœud Ready. Les pods peuvent maintenant être ordonnancés."

seed-secrets: ## 4. Sème les secrets sources du "coffre" (hors GitOps, une seule fois)
	kubectl create namespace platform-secrets --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n platform-secrets create secret generic keycloak-db \
	  --from-literal=username=keycloak \
	  --from-literal=password=$$(openssl rand -hex 16) \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n platform-secrets create secret generic llm-openai \
	  --from-literal=apiKey="$${OPENAI_API_KEY:-sk-remplacer}" \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ">> Secrets sources en place. ESO les projettera dans keycloak et agentgateway-system."

install-argocd: ## 5. Amorce Argo CD avec EXACTEMENT le chart et les valeurs de Git
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
	helm repo update argo >/dev/null
	helm upgrade --install argocd argo/argo-cd \
	  --version $(ARGOCD_CHART) \
	  --namespace argocd --create-namespace \
	  -f base/argocd/values.yaml \
	  -f clusters/$(CLUSTER)/values/argocd.yaml \
	  --wait
	@echo ">> Argo CD amorcé. L'Application 'argocd' reprendra la main au bootstrap."

bootstrap: ## 6. Passe la main à Argo CD : Application root + AppProjects + ApplicationSet
	kubectl apply -k bootstrap/
	@echo ">> Argo CD gère désormais projects/, l'ApplicationSet clusters, et adopte"
	@echo "   gateway-api (wave -20), cilium (-10) et lui-même (5)."

up: kind-up install-gateway-api install-cilium seed-secrets install-argocd bootstrap ## Enchaîne les 6 étapes

adopt-check: ## Vérifie que l'adoption des composants amorcés est bien un no-op
	@for a in gateway-api cilium argocd; do \
	  printf '%-14s ' "$$a"; \
	  kubectl -n argocd get application $$a \
	    -o jsonpath='{.status.sync.status}{"  "}{.status.health.status}{"\n"}' 2>/dev/null \
	    || echo "(pas encore créée)"; \
	done
	@echo ">> Attendu : Synced / Healthy. Un OutOfSync signale un écart entre"
	@echo "   les valeurs d'amorçage et celles de Git."

##@ Exploitation

status: ## Etat des Applications, dans l'ordre des waves
	kubectl -n argocd get applications.argoproj.io \
	  -o custom-columns='WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
	  | (read -r h; echo "$$h"; sort -n)

urls: ## Vérifie la Gateway de plateforme et affiche les URLs
	@echo ">> Gateway de plateforme (classe cilium, host network + extraPortMappings) :"
	@kubectl -n platform-gateway get gateway platform \
	  -o custom-columns='NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status' 2>/dev/null || true
	@echo
	@echo "   Argo CD  : http://$(ARGOCD_HOST)"
	@echo "   Keycloak : http://$(KC_HOST)   (alice/alice, bob/bob)"
	@echo "   Hubble   : http://$(HUBBLE_HOST)"
	@echo
	@echo ">> Aucun port-forward n'est nécessaire ni possible ici : en mode host"
	@echo "   network, Cilium ne crée pas de Service LoadBalancer, et son Service"
	@echo "   n'a de toute façon aucun pod derrière lui (endpoint sentinelle du"
	@echo "   datapath BPF). Envoy écoute sur le nœud, kind publie 8080."
	@echo
	@echo ">> Gateway IA : make port-forward-ai (celle-là est un Deployment normal)"

port-forward-ai: ## Expose la Gateway IA sur localhost:8081 (Deployment classique)
	kubectl -n agentgateway-system port-forward svc/ai 8081:80

admin-password: ## Mot de passe admin local d'Argo CD (issue de secours)
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

token: ## Récupère un JWT Keycloak pour alice (USER=bob pour l'autre)
	@curl -s -X POST "http://$(KC_HOST)/realms/platform/protocol/openid-connect/token" \
	  -d grant_type=password -d client_id=mcp-client \
	  -d username=$${USER_NAME:-alice} -d password=$${USER_PASS:-alice} \
	  -d scope="openid groups agentgateway-audience" | jq -r .access_token

demo-mcp: ## Appelle le serveur MCP à travers AgentGateway avec un JWT
	@TOKEN=$$($(MAKE) -s token); \
	curl -s -H "Authorization: Bearer $$TOKEN" \
	     -H 'Content-Type: application/json' \
	     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
	     http://localhost:8081/mcp | jq .

demo-mcp-anonymous: ## Le même appel sans token : doit être refusé
	@curl -s -i -H 'Content-Type: application/json' \
	     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
	     http://localhost:8081/mcp | head -20

##@ Nettoyage

down: ## Supprime le cluster kind
	kind delete cluster --name kind

.PHONY: help validate waves kind-up install-gateway-api install-cilium \
        install-argocd seed-secrets bootstrap up adopt-check \
        status urls port-forward-ai admin-password token demo-mcp \
        demo-mcp-anonymous down
