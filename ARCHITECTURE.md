# Décisions d'architecture

Ce document explique **pourquoi** le dépôt est structuré ainsi, en confrontant
chaque choix aux recommandations du livre blanc *GitOps Best Practices — 2026
Edition* (Akuity). Il sert autant de justification technique que de trame pour la
présentation.

---

## 1. Monorepo, un dossier par cluster

Le ebook (§3.4) refuse de trancher entre monorepo et polyrepo, et rappelle la loi
de Conway : la structure suit l'organisation, pas l'inverse.

Ici : **un monorepo**, parce que le socle est possédé par une seule équipe
plateforme et que la valeur recherchée est la revue d'un changement transverse en
une seule pull request. La limite connue du monorepo (§3.4.1) est que le moindre
commit change le SHA et réveille tous les Argo CD du parc ; à l'échelle d'un
socle interne, c'est un coût acceptable. Le jour où plusieurs équipes se
disputent le dépôt, la frontière naturelle est déjà tracée : `apps/` part dans un
dépôt par équipe, `base/` et `clusters/` restent à la plateforme, et les
`AppProject` sont déjà là pour l'appliquer.

## 2. Pas de branche par environnement

§2.2 : les environnements sont des **dossiers**, jamais des branches. Une seule
branche `main`, trunk-based. `clusters/lab/` est un dossier ; un futur
`clusters/prod/` en sera un autre. La promotion ne sera jamais un merge — voir
§8 pour la suite (Kargo).

## 3. Kustomize pour les manifests, Helm pour les charts upstream, jamais l'inverse

§1.3 : « ce n'est pas Kustomize *contre* Helm, c'est Kustomize *et* Helm ».

La règle appliquée dans ce dépôt :

- **Un chart upstream reste un chart upstream.** Aucun `helm template` figé,
  aucun wrapper, aucun `helmCharts:` dans un kustomization. La version est
  épinglée dans l'`Application`, et le diff d'une montée de version se lit sur
  une ligne.
- **Les valeurs vivent dans Git, par couches**, via le pattern *multi-sources*
  d'Argo CD :

  ```yaml
  sources:
  - repoURL: https://helm.cilium.io
    chart: cilium
    targetRevision: 1.19.6
    helm:
      valueFiles:
      - $values/base/cilium/values.yaml            # commun à tous les clusters
      - $values/clusters/lab/values/cilium.yaml    # delta du cluster
  - repoURL: https://github.com/EvannDev/kubernetes-core.git
    ref: values
  ```

  C'est la réponse directe à §3.1 (« Keeping it DRY ») et §3.2
  (« Parameterize ») : ce qui est connu d'avance est patché, ce qui dépend du
  cluster est paramétré.
- **Kustomize pour tout ce qui est du YAML brut** : CR Keycloak, Gateway,
  policies AgentGateway. Les overlays `clusters/lab/*/kustomization.yaml` ne
  contiennent que des deltas réels (URLs, issuer), pas du remplissage.

## 4. App-of-apps, et pas ApplicationSet, pour la plateforme

C'est la décision la plus contre-intuitive du dépôt, donc celle qui mérite une
diapositive.

Un `ApplicationSet` avec un générateur `git directories` sur `base/*` est plus
court à écrire. Mais **les Applications générées par un ApplicationSet partent
toutes en parallèle** : `argocd.argoproj.io/sync-wave` n'ordonne les ressources
qu'à l'intérieur d'**une même** synchronisation. Conséquence concrète : les
policies AgentGateway sont appliquées avant leurs CRD, Cilium avant les CRD
Gateway API, le CR Keycloak avant son opérateur. Argo CD finit par converger à
force de retry, mais le bootstrap est bruyant et non déterministe — inutilisable
en démo.

Un **app-of-apps** (`clusters/<cluster>/platform/` = un dossier de CR
`Application`) est synchronisé comme une ressource unique : les sync-waves
s'appliquent, et Argo CD attend la **santé** de chaque wave avant de passer à la
suivante. D'où la table d'ordonnancement du README.

L'`ApplicationSet` est conservé là où il excelle et où l'ordre est indifférent :

- `bootstrap/applicationset-clusters.yaml` — découverte des clusters
  (`clusters/*/cluster.yaml`) ;
- `clusters/lab/platform/90-apps.yaml` — découverte des applications
  (`apps/*`), qui sont indépendantes entre elles.

## 5. L'amorce impérative, et pourquoi elle est irréductible

C'est le point que tout le monde découvre au premier `kind create cluster`, et
il mérite une diapositive parce qu'il dit quelque chose de vrai sur GitOps.

**GitOps ne peut pas s'amorcer lui-même.** Argo CD est un pod. Un pod a besoin
d'un CNI pour obtenir une IP. Le nœud reste `NotReady` tant que le CNI n'est pas
là, et le seul type de charge qui s'y ordonnance est celui qui tolère
`node.kubernetes.io/not-ready` — ce que fait le DaemonSet Cilium, et ce que ne
fait pas Argo CD. Et comme Cilium est configuré ici avec `gatewayAPI.enabled:
true`, il exige lui-même que les CRD Gateway API soient déjà présentes.

D'où une amorce à trois composants, dans cet ordre : **CRD Gateway API →
Cilium → Argo CD**. Aucune astuce ne la supprime ; la déplacer ailleurs (Terraform,
un module d'installation du cloud provider, une image de nœud) ne fait que
changer qui la porte.

Ce qu'on peut faire, en revanche, c'est la rendre **inoffensive** : courte,
idempotente, et surtout **identique à ce que Git décrit**.

```
make kind-up             # cluster nu, NotReady
make install-gateway-api # kubectl apply --server-side, v1.6.1
make install-cilium      # chart 1.19.6 + base/cilium/values.yaml + clusters/lab/values/cilium.yaml
make seed-secrets        # secrets sources du coffre
make install-argocd      # chart 10.3.0 + base/argocd/values.yaml + clusters/lab/values/argocd.yaml
make bootstrap           # kubectl apply -k bootstrap/  <- le seul kubectl du projet
```

Chaque `helm upgrade --install` de l'amorce consomme **les mêmes fichiers de
valeurs** que l'`Application` correspondante, et le même dépôt de chart : le
chart Cilium vient de `https://helm.cilium.io` des deux côtés (et non du miroir
OCI `quay.io/cilium/charts`, pour éviter deux artefacts différents pour la même
version).

Conséquence : quand Argo CD démarre, les `Application` `gateway-api` (wave -20),
`cilium` (-10) et `argocd` (5) **adoptent** des ressources déjà correctes. La
synchronisation est un no-op. `make adopt-check` le vérifie explicitement — et un
`OutOfSync` sur l'un des trois est un signal utile : l'amorce a dérivé de Git.

Reste un résidu assumé : les *release secrets* Helm créés par l'amorce restent
dans le cluster alors qu'Argo CD n'utilise pas Helm pour appliquer (il rend puis
applique). Ils sont inertes ; on peut les supprimer une fois l'adoption
confirmée, ou les laisser.

### Argo CD auto-géré, en particulier

Une fois amorcé, Argo CD est géré par l'`Application` `argocd` (wave 5) : toute
évolution, montée de version incluse, passe par une pull request.

Trois points de vigilance, tous traités dans `30-argocd.yaml` :

- `ServerSideApply=true` est **documenté comme obligatoire** pour l'auto-gestion :
  le CRD `ApplicationSet` dépasse la limite du client-side apply.
- `argocd-server` écrit lui-même `server.secretkey` et le hash du mot de passe
  admin dans `argocd-secret`. Sans `ignoreDifferences` sur ces clés, `selfHeal`
  et le serveur se disputent le Secret en boucle.
- Les clés de `argocd-cmd-params-cm` (`configs.params`, dont `server.insecure`)
  sont consommées comme arguments de conteneur : elles nécessitent un
  `rollout restart` de `argocd-server`. Celles de `argocd-cm` (`oidc.config`,
  `policy.csv`) sont relues à chaud.

Garder `admin.enabled: true` n'est pas de la négligence : une `oidc.config`
invalide rend l'UI inaccessible, et il faut alors un compte local pour réparer.

## 6. Identité : PKCE plutôt qu'un client secret

Argo CD est branché **directement** sur Keycloak (`oidc.config`), sans Dex : un
pod et une couche de moins.

Le client `argocd` est **public avec PKCE** (`enablePKCEAuthentication: true`,
`pkce.code.challenge.method: S256`). Donc : aucun client secret à provisionner
dans `argocd-secret`, aucun secret à faire tourner, aucun secret à chiffrer.
C'est le mode adapté à une UI.

Si votre politique interne impose un client confidentiel, la variante est déjà
outillée par le dépôt :

```yaml
# clusters/<cluster>/values/argocd.yaml
oidc.config: |
  clientSecret: $keycloak-oidc:oidc.keycloak.clientSecret
```

```yaml
# ExternalSecret dans le namespace argocd
target:
  name: keycloak-oidc
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: argocd   # OBLIGATOIRE, sinon Argo CD ignore le Secret
```

Ne jamais écrire dans `argocd-secret` : c'est Argo CD qui le mute. Un Secret
séparé portant le label `app.kubernetes.io/part-of: argocd` est la voie propre.

Point à ne pas rater : Keycloak **n'émet pas** le claim `groups` par défaut. Il
faut un *client scope* dédié avec un `oidc-group-membership-mapper` et
`full.path: "false"` — sinon le claim vaut `/platform-admins` et ne correspond
plus à `policy.csv`. Le scope est déclaré dans
`base/keycloak/realm-platform.yaml`.

### 6.1 L'issuer est une seule chaîne pour deux réseaux

Depuis le passage aux domaines publics servis par Pangolin
(`https://idp.evann-deb.fr`), le problème décrit ici **ne se pose plus** : le nom
résout de la même façon depuis le Mac et depuis les pods. La section reste,
parce que le piège est classique, que le message d'erreur est illisible, et que
le raisonnement resservira au premier lab exposé en local. Ce qui suit décrit
donc l'état antérieur, en `*.127.0.0.1.nip.io:8080`.

Celle-là mérite une diapositive, parce que le message d'erreur ne dit
absolument pas ce qui se passe :

```
failed to query provider "http://keycloak.127.0.0.1.nip.io:8080/realms/platform":
404 Not Found: <octets gzip illisibles>
```

Un flux OIDC a **deux chemins réseau**, et l'issuer est la *même chaîne* pour
les deux :

| Acteur | Chemin | Résolution de `keycloak.127.0.0.1.nip.io` |
|---|---|---|
| Le navigateur, sur le Mac | frontchannel : redirection, login, retour | `127.0.0.1` → port publié par kind → Gateway → Keycloak ✔ |
| Le pod `argocd-server` | backchannel : `.well-known/openid-configuration`, JWKS | `127.0.0.1` → **le pod lui-même** ✘

Argo CD interroge donc son propre serveur web, qui répond un 404 gzippé — d'où
la bouillie d'octets dans le message. Ce n'est ni le realm, ni le client, ni
PKCE, ni la Gateway.

C'est le problème classique du **DNS à double horizon**. En production il ne se
pose pas : l'IdP a un nom DNS résolvable partout. En lab, on le reproduisait avec
une réécriture CoreDNS (`clusters/lab/cluster-dns/`) :

```
rewrite name keycloak.127.0.0.1.nip.io kc-service.keycloak.svc.cluster.local
```

Le navigateur continuait de passer par la Gateway, les pods coupaient au plus
court vers le Service. Deux coups de chance rendaient la manœuvre indolore :
`kc-service` écoute sur 8080, comme l'URL publique ; et l'en-tête `Host` restait
`keycloak.127.0.0.1.nip.io:8080`, donc le document de découverte annonçait le bon
`issuer` et Argo CD validait la correspondance.

**Ce que Pangolin a changé.** L'IdP a maintenant un nom résolvable partout,
c'est-à-dire exactement la situation de production évoquée plus haut : la
réécriture a été retirée. Elle serait d'ailleurs devenue nuisible, l'issuer étant
en `https` alors que `kc-service` écoute en clair — rediriger le nom vers le
Service ferait tenter une poignée de main TLS contre un serveur en HTTP.

La contrepartie est un **backchannel en épingle à cheveux** : `argocd-server` et
Open WebUI sortent sur Internet, atteignent Pangolin, et reviennent dans le
cluster par le tunnel Newt pour lire `.well-known/openid-configuration`. Quelques
millisecondes de plus, et une dépendance du SSO au tunnel — mais l'interface
emprunte déjà ce chemin, donc aucun mode de panne nouveau n'apparaît.

**Détail qui vaut le détour : AgentGateway n'est pas concerné.** Sa policy
récupère les JWKS via un `backendRef` vers le Service `kc-service`, sans jamais
résoudre le nom public, et ne compare l'`issuer` que comme une chaîne. La
différence entre « faire confiance à un émetteur » et « aller lui parler » a des
conséquences très concrètes sur la topologie réseau.

Contrepartie assumée : cette `Application` prend possession du ConfigMap
`coredns` créé par kubeadm — Argo CD remplace, il ne patche pas. C'est acceptable
sur un cluster de lab dont on est propriétaire. Sur un cluster managé, on
passerait par le point d'extension du fournisseur (par exemple le ConfigMap
`coredns-custom` sur AKS) plutôt que par le Corefile lui-même. `prune: false`
évite qu'une suppression de l'Application n'emporte le DNS du cluster.

## 7. Les secrets : ESO, et le coffre est remplaçable

§6.7.2 du ebook : Sealed Secrets et SOPS déchiffrent *dans* le cluster au moment
du rendu, ce qui les rend incompatibles avec le pattern *rendered manifests* et
place des secrets en clair dans les artefacts. La recommandation est **External
Secrets Operator** : Git ne contient que des *références*.

Dans ce lab, le `ClusterSecretStore` utilise le provider `kubernetes` et lit le
namespace `platform-secrets`, semé hors GitOps par `make seed-secrets`. Ce n'est
pas un vrai coffre — c'est un **point de substitution** : passer en production
consiste à patcher `spec.provider` (vault, aws, gcpsm, 1password) dans
`clusters/<cluster>/external-secrets/`. **Aucun `ExternalSecret` de composant ne
change.** C'est tout l'intérêt de l'indirection, et ça se démontre en une
diapositive.

Deux détails qui font perdre une heure quand on les ignore :

- le verbe `selfsubjectrulesreviews/create` est requis, ESO valide le store avec ;
- `caProvider.namespace` et `auth.serviceAccount.namespace` sont **obligatoires**
  dans un `ClusterSecretStore` (et interdits dans un `SecretStore`).

## 8. Deux GatewayClass, et c'est volontaire

| Classe | Contrôleur | Trafic |
|---|---|---|
| `cilium` | `io.cilium/gateway-controller` | north-south classique : UI Argo CD, Keycloak |
| `agentgateway` | `agentgateway.dev/agentgateway` | LLM, MCP, A2A — là où vit la gouvernance |

La cohabitation est propre pour deux raisons :

1. **Ni Cilium ni AgentGateway n'installent les CRD Gateway API** — les deux
   documentations demandent de les pré-installer. Il n'y a donc pas de conflit de
   propriété *par construction*, à condition qu'une seule `Application` en soit
   propriétaire : c'est le rôle de `gateway-api` (wave -20), et c'est la raison
   pour laquelle elle est seule dans le projet `network`.
2. Les `controllerName` sont disjoints : chaque contrôleur ignore les `Gateway`
   de l'autre. La sélection se fait uniquement par `gatewayClassName`.

Version retenue : **Gateway API v1.6.1, canal experimental**.

Le choix du canal n'est pas un détail de confort, et c'est un bon exemple de ce
que « propriétaire unique des CRD » veut dire concrètement : la décision est
prise une fois, pour les deux implémentations à la fois.

- v1.6.1 satisfait le plancher d'AgentGateway 1.4 (v1.6, `TCPRoute` passé en
  `v1`) et le niveau déclaré par Cilium 1.19.
- Mais le contrôleur Gateway API de Cilium 1.19 construit un index de champ sur
  `TLSRoute` en `gateway.networking.k8s.io/v1alpha2`. Dans le canal **standard**
  de v1.6, cette version n'est plus servie (`served: false`) — elle n'existe que
  dans le canal **experimental**. Résultat avec le canal standard :

  ```
  level=error msg="Invoke failed" error="failed to create gateway controller:
  failed to setup reconciler: failed to setup field indexer
  \"backendServiceTLSRouteIndex\": no matches for kind \"TLSRoute\"
  in version \"gateway.networking.k8s.io/v1alpha2\""
  ```

  La documentation Cilium le dit à demi-mot : « si vous avez utilisé la ressource
  `TLSRoute` avant Cilium v1.20, installez la version *Experimental* ».

Le canal experimental est un **sur-ensemble strict** : il sert `v1` pour tout, donc
AgentGateway est indifférent au changement — et installer ces CRD n'active pas
pour autant ses fonctionnalités expérimentales, qui dépendent d'une variable
d'environnement dédiée. Le coût réel est de deux CRD inutilisées
(`XBackendTrafficPolicy`, `XMesh`, groupe `gateway.networking.x-k8s.io`).

L'alternative — canal standard + le seul CRD `TLSRoute` experimental — évite ces
deux CRD mais impose de faire évoluer deux canaux ensemble à chaque montée de
version. Un seul canal, une seule décision.

Corollaire : `make install-gateway-api` applique `experimental-install.yaml` et
l'`Application` pointe sur `config/crd/experimental`. Les deux doivent rester
alignés, sinon l'adoption au wave -20 se solde par un `OutOfSync`.

### 8.1 Comment on atteint réellement ces Gateway depuis un Mac

Le sujet paraît trivial et ne l'est pas ; il vaut une diapositive parce qu'il
révèle une différence de nature entre les deux implémentations.

**La Gateway `agentgateway` est un Deployment ordinaire.** Le contrôleur
provisionne un Deployment et un Service avec de vrais pods derrière. Un
`kubectl port-forward svc/ai 8081:80` fonctionne donc sans rien de particulier —
c'est ce que fait `make port-forward-ai`.

**La Gateway `cilium`, non.** Cilium ne déploie pas de proxy dédié : le trafic
est traité par le DaemonSet `cilium-envoy`, qui tourne en host network, et le
service est programmé dans le datapath BPF. Le Service `cilium-gateway-platform`
n'a aucun pod derrière lui ; son EndpointSlice contient un endpoint sentinelle :

```
NAME                      ADDRESSTYPE   PORTS   ENDPOINTS
cilium-gateway-platform   IPv4          9999    192.192.192.192
```

`kubectl port-forward` cherche un pod, n'en trouve pas, et échoue. Ce n'est pas
un bug : c'est la conséquence de la façon dont Cilium implémente le load
balancing.

Restait le Service `LoadBalancer`. Sur kind il n'y a pas de cloud provider ;
avec `cloud-provider-kind` une IP est bien attribuée, mais elle appartient au
réseau Docker (`172.18.0.0/16`) — non routable depuis macOS sur Docker Desktop,
où le démon tourne dans une VM.

**Première solution, aujourd'hui abandonnée : le mode host network.** Envoy
bindait le port du listener sur le réseau du nœud (`gatewayAPI.hostNetwork`
dans les valeurs Cilium) et kind le publiait vers `localhost`
(`extraPortMappings`). Deux contreparties : host network et Service
`LoadBalancer` sont mutuellement exclusifs — Cilium crée un `NodePort` à la
place — et un listener sous 1024 aurait exigé
`envoy.securityContext.capabilities.keepCapNetBindService=true`, d'où un
listener patché en **8080** et ce port dans toutes les URLs du lab.

**Solution retenue : le tunnel sortant de Newt.**

Toute la difficulté venait du sens du flux : on cherchait à faire ENTRER du
trafic depuis macOS vers un cluster enfermé dans Docker. Newt renverse la
question. Le pod `newt` vit DANS le cluster et ouvre lui-même la connexion vers
Pangolin ; c'est Pangolin qui expose les domaines publics et fait redescendre
les requêtes par ce tunnel. Newt joint alors la Gateway comme n'importe quel
pod :

```
cilium-gateway-platform.platform-gateway.svc.cluster.local:80
```

Ce qui disparaît, en cascade :

- le bloc `gatewayAPI.hostNetwork` des valeurs Cilium — le Service
  `LoadBalancer` réapparaît, son `EXTERNAL-IP` reste `<pending>` sur kind et
  c'est sans importance : seul le `ClusterIP` est utilisé ;
- le patch de port du listener — retour au **80** de `base/`, sans question de
  capability, puisqu'il s'agit désormais d'un port de Service et non d'un bind
  sur le nœud ;
- les `extraPortMappings` de `kind-cluster.yaml` — plus rien ne traverse la
  frontière Docker.

Le port-forward, lui, reste impossible sur ce Service pour la raison décrite
plus haut (aucun pod, endpoint sentinelle). Ce n'est plus un problème : aucun
accès ne passe par l'hôte.

`extraPortMappings` ne pouvant être ni ajouté ni retiré à chaud, revenir sur ce
choix impose un `make down && make up`.

La `GatewayClass` elle-même n'est pas dans Git : le contrôleur AgentGateway la
crée à partir des valeurs Helm `gatewayClassName` / `controllerName`. La
déclarer aussi dans un `Application` avec `prune: true` + `selfHeal: true`
provoquerait une lutte de propriété. Même logique pour le `Deployment` et le
`Service` du data plane, générés depuis le CR `Gateway` : c'est pourquoi
`agentgateway-config` est une `Application` distincte de `agentgateway`.

## 9. Ce que la passerelle apporte, en trois manifests

C'est le cœur du Lunch & Learn. Toute la gouvernance tient dans des objets
déclaratifs, versionnés, revus en pull request.

**a. La clé d'API ne quitte jamais la passerelle**
`base/agentgateway/backend-llm.yaml` : un `AgentgatewayBackend` détient la
référence au Secret OpenAI (projeté par ESO). Les agents n'ont plus de clé : ils
présentent un JWT. Une clé, un point d'audit, une révocation.

**b. Authentification, autorisation et quota au même endroit**
`base/agentgateway/policy-llm.yaml` : un seul `AgentgatewayPolicy` porte
`jwtAuthentication` (mode `Strict`, JWKS récupéré via le Service interne de
Keycloak), une autorisation CEL sur les claims, et un `rateLimit`. AgentGateway
sait aussi limiter en **tokens** et pas seulement en requêtes
(`rateLimit.global`, avec un service RLS externe) — c'est la vraie réponse à
« qui a brûlé le budget ? ».

**c. L'autorisation porte sur l'OUTIL, pas sur le serveur**
`apps/mcp-website-fetcher/policy-tool-rbac.yaml` : `mcp.tool.name` est une
variable CEL de premier ordre. Deux utilisateurs, le même serveur MCP, deux
périmètres d'outils — décidés par un JWT et une ligne dans Git. C'est la démo qui
fait comprendre le sujet en dix secondes, et c'est strictement infaisable quand
chaque application porte sa propre clé.

Piège de la 1.4 à connaître avant de monter sur scène : un refus en phase requête
renvoie **HTTP 200** avec un corps JSON-RPC d'erreur, pas un code non-2xx.

## 10. Ce qui a été délibérément écarté

### Rendered Manifests (§6)

Le chapitre 6 du ebook est convaincant : l'état désiré stocké dans Git devrait
être le YAML **rendu**, immuable, sans abstraction de dernière minute. Les
avantages sont réels — diff lisible (une ligne de version de chart devient 400
lignes explicites), moins de risque à la montée de version d'Argo CD, repo-server
déchargé, protection de branche par environnement.

Ce n'est pas retenu **ici** parce que le coût est frontal :

- un pipeline CI (ou le *Source Hydrator* natif d'Argo CD) à opérer et à
  surveiller ;
- une branche par cluster, avec des règles de protection ;
- et surtout, pour une présentation d'une heure : la double indirection
  Git → CI → branche → Argo CD masque le raisonnement qu'on veut montrer.

Le chemin de migration reste ouvert et n'invalide rien de ce dépôt : la source
« dry » (`base/` + `clusters/`) devient l'entrée du *Source Hydrator*, qui pousse
le rendu sur `env/<cluster>`. Le mode `push-to-stage` (rendu poussé sur une
branche de staging puis promu par pull request) est celui qui a du sens pour la
production. Prérequis déjà satisfait : les secrets passent par ESO, donc aucun
secret en clair ne peut se retrouver dans les manifests rendus.

### Kargo (§5)

La promotion entre environnements est un problème distinct du déploiement, et
Argo CD ne le résout pas. Avec un seul cluster, Kargo n'aurait rien à promouvoir.
Dès qu'il y aura `clusters/staging/` et `clusters/prod/`, c'est la brique à
ajouter — et non des branches, ni des scripts CI, ni du cherry-pick.

### `KeycloakRealmImport` comme source de vérité durable

Le CR **ne crée que**. Si le realm existe déjà, il n'est pas mis à jour : éditer
`base/keycloak/realm-platform.yaml` et laisser Argo CD synchroniser est un
**no-op**. Acceptable pour un lab reproductible (on supprime le realm, ou le PVC
Postgres, et le Job d'import se relance), inacceptable en exploitation.

Deux options réconciliantes, par ordre de maturité :

1. **`keycloak-config-cli`** en `Job` avec les annotations
   `argocd.argoproj.io/hook: PostSync` et
   `hook-delete-policy: BeforeHookCreation` : réconciliation complète, y compris
   les suppressions (une clé présente mais vide supprime tous les objets de ce
   type). Attention au décalage de version : la 6.5.1 est compilée contre
   Keycloak 26.5.5, pas 26.7.1.
2. **`KeycloakOIDCClient`** / **`KeycloakSAMLClient`**, nouveaux en 26.7 : ils
   réconcilient vraiment (création, mise à jour, suppression). Mais ils sont
   **expérimentaux**, en `v2alpha1` (et non `v2beta1`), exigent la feature
   `client-admin-api:v2` et un Secret `<nom-du-CR>-admin` créé à la main. À
   répéter avant de le montrer en public.

### Postgres plutôt que H2 / `dev-file`

L'opérateur Keycloak lance toujours le serveur en mode production et ne
provisionne aucun PVC pour H2 : le realm serait perdu à chaque redémarrage de
pod. Combiné au point précédent (l'import ne rejoue pas), la démo deviendrait non
déterministe. Vingt lignes de Postgres suppriment toute cette classe de problème.
Sur un vrai cluster : CloudNativePG ou la base managée du cloud, et on ne garde
que le bloc `spec.db` du CR.

---

## Pistes d'évolution

| Sujet | Piste |
|---|---|
| Observabilité | kube-prometheus-stack, puis activer `podMonitor.proxy.enabled` (attention : `namespaceSelector` ne couvre que le namespace de la release) et un collecteur OTel pour `frontend.tracing`. La métrique qui compte : `agentgateway_gen_ai_client_token_usage`. |
| Quota en tokens | `rateLimit.global` avec un service de rate limiting externe, `unit: Tokens`. |
| Multi-cluster | Un dossier par cluster + `destination.server` distinct. Si la duplication de `platform/` devient pénible : soit un overlay Kustomize d'un `base/platform/`, soit un petit chart Helm d'`Application` — au prix de l'abstraction que le ebook (§6.2) recommande justement d'éviter. |
| Politiques d'admission | Kyverno ou Gatekeeper pour rendre non contournable ce que les `AppProject` décrivent aujourd'hui par convention. |
| Promotion | Kargo, quand il y aura plus d'un environnement. |
