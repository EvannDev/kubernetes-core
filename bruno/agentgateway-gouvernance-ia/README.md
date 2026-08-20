# Collection Bruno — AgentGateway, gouvernance IA

Collection [Bruno](https://usebruno.com) qui accompagne le Lunch & Learn
« gouvernance de l'IA avec AgentGateway ». Elle ne tape **que** la Gateway IA du
socle `kubernetes-core` : aucune clé de fournisseur LLM n'apparaît ici, et c'est
précisément l'argument.

## Démarrer

```bash
make up                 # cluster kind + socle GitOps
make port-forward-ai    # Gateway IA -> http://localhost:8081
```

Dans Bruno : *Open Collection* → ce dossier → **sélectionner l'environnement
`lab`**. Le premier appel déclenche l'obtention du jeton (`auto_fetch_token`).

### Si toutes les `{{variables}}` sont en rouge

Bruno s'ouvre sur **No Environment**. Dans cet état aucune variable n'est
résolue — ni dans la barre d'URL, ni dans l'onglet *Auth* — et les requêtes
partiraient avec des placeholders littéraux. Il suffit de choisir **lab** dans le
sélecteur d'environnement, en haut à droite de la fenêtre.

Un filet de sécurité est posé dans le script de pré-requête de la collection :
sans environnement sélectionné, il applique les valeurs du lab et le signale dans
la console. Dès qu'un environnement est actif, il retire ses valeurs de repli et
laisse la main à l'environnement — sans ce nettoyage, le repli masquerait un
`lab` modifié, car une variable d'exécution est prioritaire sur une variable
d'environnement.

Les tests lisent la variable *effective* (`bru.getEnvVar(k) || bru.getVar(k)`) :
ils passent dans les deux cas.

## Ports nécessaires

| Port | Quoi | Comment |
| --- | --- | --- |
| — | Keycloak (`https://idp.evann-deb.fr`) | servi par Pangolin, aucun port-forward |
| 8081 | Gateway IA | `make port-forward-ai` |
| 15020 | métriques du data plane (dossier *07*) | `kubectl -n agentgateway-system port-forward deploy/ai 15020:15020` |

## Authentification

| Où | Flux | Client Keycloak | Identité |
| --- | --- | --- | --- |
| Collection (défaut) | `password` | `mcp-client` (public, `directAccessGrantsEnabled`) | `alice` / `platform-admins` |
| Requêtes « bob » | `password`, `credentials_id: kc-bob` | `mcp-client` | `bob` / `platform-viewers` |
| Dossier *06* | `authorization_code` + **PKCE** | `opencode` (public) | celle du login navigateur |

Les jetons sont mis en cache par `credentials_id` : celui d'alice et celui de bob
coexistent, on compare les deux identités sans rien rebasculer dans l'interface.

Scope demandé : `openid groups agentgateway-audience`. Les deux claims qui font
tout le travail :

- `aud: agentgateway` — produit par le client scope `agentgateway-audience`.
  Sans lui, la passerelle répond 401 (démonstration dans *05 Refus / 3*).
- `groups` — produit par le client scope `groups`
  (`oidc-group-membership-mapper`, `full.path: "false"`). C'est ce que lisent les
  expressions CEL.

## Contenu

| Dossier | Ce qu'on montre |
| --- | --- |
| **01 Base** | découverte OIDC, JWKS, un jeton décodé à l'écran, découverte OAuth servie par la passerelle (RFC 9728) |
| **02 Models** | `/v1/models` renvoie un catalogue **propre à l'appelant** : alice voit `gpt-4o`, bob non |
| **03 Chat** | `/v1/chat/completions`, modèle ouvert, modèle réservé, streaming SSE |
| **04 MCP** | `initialize`, `tools/list`, `tools/call fetch` à travers la même passerelle |
| **05 Refus** | six refus, chacun pour une raison différente — c'est le cœur de la démo |
| **06 OAuth PKCE** | le vrai flux navigateur, sans aucun secret sur le poste |
| **07 Observabilité** | `agentgateway_gen_ai_client_token_usage` : le coût, par modèle |

Les tests ne vérifient pas seulement que ça marche : ils vérifient que **ça
échoue pour la bonne raison**.

## Où vit chaque décision

| Décision | Ressource Kubernetes |
| --- | --- |
| QUI es-tu (JWT : issuer, audience) et à quel débit | `AgentgatewayPolicy/ai-authn`, sur la **Gateway** |
| As-tu le droit d'utiliser CE modèle | `AgentgatewayModel/gpt-4o`, `policies.authorization` |
| As-tu le droit d'appeler CET outil MCP | `AgentgatewayPolicy/mcp-tool-rbac`, sur le **backend** |

Authentification à la porte, autorisation au plus près de la ressource.

## Pièges déjà encodés dans la collection

1. **L'issuer doit correspondre au caractère près** au claim `iss`. Le test de
   *01 Base / Discovery OIDC* le vérifie : c'est la cause n°1 des 401
   inexplicables.
2. **`/.well-known/*` échappe à la validation JWT** parce que la policy porte un
   bloc `mcp:`. Sans lui, il faudrait un jeton pour apprendre comment en obtenir
   un.
3. **Un refus MCP en phase requête renvoie HTTP 200** (AgentGateway 1.4) avec un
   corps JSON-RPC d'erreur. Un client qui ne regarde que le statut croit que tout
   va bien. *05 Refus / 5* l'asserte explicitement.
4. **Scope `agentgateway-audience` oublié = 401 incompréhensible.**
   *05 Refus / 3* le reproduit à la demande.
5. **`profile` et `email` peuvent ne pas exister** dans le realm : déclarer
   `clientScopes` désactive la création des scopes intégrés de Keycloak. Le test
   sur `scopes_supported` sert de sentinelle.

## Exécution en CLI

```bash
npm install -g @usebruno/cli
bru run "01 Base" "02 Models" "03 Chat" "04 MCP" "05 Refus" "07 Observabilite" --env lab
```

Le dossier *06 OAuth PKCE* nécessite un navigateur : il ne passe pas en CLI.
