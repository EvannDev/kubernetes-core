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
# Domaines publics, servis par Pangolin (TLS terminé chez lui, tunnel Newt
# jusqu'à la Gateway). Plus de port : ce sont des URLs https standard.
KC_HOST        ?= idp.evann-deb.fr
ARGOCD_HOST    ?= argocd.evann-deb.fr
HUBBLE_HOST    ?= hubble.evann-deb.fr
OWUI_HOST      ?= openwebui.evann-deb.fr

##@ Général
# Secrets locaux (jamais commités, cf. .gitignore). `include` n'en fait que des
# variables Make : il faut les exporter pour que les recettes, qui les lisent en
# expansion shell ($${VAR}), les voient réellement. La liste est dérivée du
# fichier, donc une nouvelle clé dans .env est disponible sans toucher ici.
-include .env
export $(shell sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' .env 2>/dev/null)


help: ## Affiche cette aide
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Validation (aucun cluster requis)

validate: ## Rend tous les kustomize build et vérifie que le YAML est valide
	@set -e; \
	for d in bootstrap projects clusters/$(CLUSTER)/platform \
	         base/external-secrets base/keycloak base/platform-gateway base/agentgateway \
	         base/pangolin clusters/$(CLUSTER)/cluster-dns \
	         clusters/$(CLUSTER)/external-secrets clusters/$(CLUSTER)/keycloak \
	         clusters/$(CLUSTER)/platform-gateway clusters/$(CLUSTER)/agentgateway \
	         clusters/$(CLUSTER)/open-webui clusters/$(CLUSTER)/argocd-mcp \
	         clusters/$(CLUSTER)/pangolin \
	         apps/mcp-website-fetcher; do \
	  printf '%-45s' "kustomize build $$d"; \
	  kustomize build $$d > /dev/null && echo OK; \
	done

KUSTOMIZE_DIRS := bootstrap projects \
  base/external-secrets base/keycloak base/platform-gateway base/agentgateway \
  base/pangolin \
  clusters/$(CLUSTER)/platform clusters/$(CLUSTER)/cluster-dns \
  clusters/$(CLUSTER)/external-secrets clusters/$(CLUSTER)/keycloak \
  clusters/$(CLUSTER)/platform-gateway clusters/$(CLUSTER)/agentgateway \
  clusters/$(CLUSTER)/open-webui clusters/$(CLUSTER)/argocd-mcp \
  clusters/$(CLUSTER)/pangolin \
  apps/mcp-website-fetcher

validate-crs: ## Valide les CR contre les CRD upstream : schéma ET règles CEL
	@pip install -q --disable-pip-version-check pyyaml jsonschema cel-python 2>/dev/null || true
	python3 hack/validate-crs.py $(KUSTOMIZE_DIRS)

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
	kubectl -n platform-secrets create secret generic open-webui-oidc \
	  --from-literal=clientSecret=$$(openssl rand -hex 24) \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n platform-secrets create secret generic llm-openai \
	  --from-literal=apiKey="$${OPENAI_API_KEY:-sk-remplacer}" \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n platform-secrets create secret generic newt-main-tunnel-auth \
	  --from-literal=PANGOLIN_ENDPOINT="$${PANGOLIN_ENDPOINT}" \
	  --from-literal=NEWT_ID="$${NEWT_ID}" \
	  --from-literal=NEWT_SECRET="$${NEWT_SECRET}" \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ">> Secrets sources en place. ESO les projettera dans keycloak et agentgateway-system."

seed-argocd-mcp-token: ## Génère le token du compte MCP et le dépose dans le coffre
	# Le compte `mcp` et sa capacité apiKey sont déclarés dans base/argocd/values.yaml.
	# Le token, lui, ne peut pas être déclaratif : Argo CD le génère.
	@kubectl -n platform-secrets create secret generic argocd-mcp \
	  --from-literal=token="$$(argocd account generate-token --account mcp --grpc-web)" \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ">> Token déposé. ESO le projettera dans le namespace argocd."

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
	@echo ">> Gateway de plateforme (classe cilium, jointe par Newt via son ClusterIP) :"
	@kubectl -n platform-gateway get gateway platform \
	  -o custom-columns='NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status' 2>/dev/null || true
	@echo
	@echo "   Argo CD  : https://$(ARGOCD_HOST)"
	@echo "   Keycloak : https://$(KC_HOST)   (alice/alice, bob/bob)"
	@echo "   Hubble   : https://$(HUBBLE_HOST)"
	@echo "   Open WebUI : https://$(OWUI_HOST)"
	@echo
	@echo ">> Ces URLs sont servies par Pangolin : TLS terminé chez lui, trafic"
	@echo "   acheminé par le tunnel Newt. Les cibles à déclarer côté Pangolin :"
	@echo "   cilium-gateway-platform.platform-gateway.svc.cluster.local:80"
	@echo ">> Le port-forward reste impossible sur ce Service : il n'a aucun pod"
	@echo "   derrière lui, seulement l'endpoint sentinelle du datapath BPF."
	@echo "   C'est sans conséquence, plus rien n'entre par l'hôte."
	@echo
	@echo ">> Gateway IA : make port-forward-ai (celle-là est un Deployment normal)"

port-forward-ai: ## Expose la Gateway IA sur localhost:8081 (Deployment classique)
	kubectl -n agentgateway-system port-forward svc/ai 8081:80

admin-password: ## Mot de passe admin local d'Argo CD (issue de secours)
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

token: ## Récupère un JWT Keycloak pour alice (USER=bob pour l'autre)
	@curl -s -X POST "https://$(KC_HOST)/realms/platform/protocol/openid-connect/token" \
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

##@ Modèles locaux (Ollama, sur le Mac)

# Ollama reste HORS du cluster : Docker Desktop ne passe pas le GPU, un pod dans
# kind tournerait en CPU seul. Le flux va donc du cluster vers l'hôte, par
# host.docker.internal — rien à publier, aucun extraPortMappings à remettre.
# Le catalogue correspondant est dans base/agentgateway/models-ollama.yaml.

OLLAMA_MODELS ?= qwen3:8b llama3.2:3b

ollama-models: ## Tire les modèles locaux servis par la Gateway IA
	@for m in $(OLLAMA_MODELS); do echo ">> ollama pull $$m"; ollama pull "$$m"; done
	@ollama list

ollama-serve: ## Lance Ollama en écoute sur toutes les interfaces (bloquant)
	# Par défaut Ollama n'écoute que sur 127.0.0.1 : inatteignable depuis un
	# conteneur. OLLAMA_HOST=0.0.0.0 est LA condition pour que la passerelle
	# puisse le joindre. Si le service brew tourne déjà, il tient le port :
	# `brew services stop ollama` d'abord.
	OLLAMA_HOST=0.0.0.0:11434 ollama serve

ollama-check: ## Vérifie qu'Ollama est joignable DEPUIS le cluster (le seul test qui compte)
	@kubectl run ollama-check --rm -i --restart=Never --quiet \
	  --image=curlimages/curl:8.11.1 -- \
	  curl -sS -m 5 http://host.docker.internal:11434/api/tags \
	  | jq -r '.models[].name' \
	  || echo ">> Echec. Vérifier que 'make ollama-serve' tourne et écoute sur 0.0.0.0"

demo-llm-local: ## Chat avec un modèle local, en tant que bob (non admin)
	# Montre que la règle se pose par modèle : bob n'a pas accès à gpt-4o mais
	# discute avec un modèle local, avec le MÊME token sur la MÊME passerelle.
	@TOKEN=$$(USER_NAME=$${USER_NAME:-bob} USER_PASS=$${USER_PASS:-bob} $(MAKE) -s token); \
	curl -s -H "Authorization: Bearer $$TOKEN" \
	     -H 'Content-Type: application/json' \
	     -d '{"model":"$(firstword $(OLLAMA_MODELS))","messages":[{"role":"user","content":"Réponds en une phrase : à quoi sert une passerelle IA ?"}]}' \
	     http://localhost:8081/v1/chat/completions | jq .

models-catalog: ## Catalogue vu par un appelant donné (USER_NAME=alice pour comparer)
	# Le même appel, deux réponses : model_list_response() filtre /v1/models sur
	# visibility ET sur les règles d'autorisation de chaque AgentgatewayModel.
	@TOKEN=$$($(MAKE) -s token); \
	curl -s -H "Authorization: Bearer $$TOKEN" http://localhost:8081/v1/models | jq -r '.data[].id'

##@ Nettoyage

down: ## Supprime le cluster kind
	kind delete cluster --name kind

.PHONY: help validate validate-crs waves kind-up install-gateway-api install-cilium \
        install-argocd seed-secrets bootstrap up adopt-check \
        status urls port-forward-ai admin-password token demo-mcp \
        demo-mcp-anonymous ollama-models ollama-serve ollama-check \
        demo-llm-local models-catalog down
