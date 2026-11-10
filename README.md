# Nooty

Application iPad personnelle de prise de notes à l'Apple Pencil. Native (Swift, UIKit, PencilKit),
local-first, sans compte ni abonnement. Code, format de fichier et identité visuelle indépendants.

**État : phase 0, prototype d'écriture.** Une seule page, pour valider l'écriture et la chaîne
compilation → installation avant de construire la bibliothèque et les carnets.

## Installer sur l'iPad (sans Mac)

L'application est compilée par les Mac de GitHub Actions (gratuit pour un dépôt public),
puis signée et installée depuis un PC Windows avec Sideloadly.

1. Onglet **Actions** du dépôt → dernière exécution réussie du workflow **iOS**.
2. En bas de la page, section *Artifacts* : télécharger **Nooty-ipa**, puis le dézipper pour obtenir `Nooty.ipa`.
3. iPad branché au PC, ouvrir Sideloadly, glisser `Nooty.ipa`, saisir l'identifiant Apple, lancer.
4. Première fois seulement, sur l'iPad : *Réglages → Général → VPN et gestion de l'appareil* → faire confiance au profil.
   Si iPadOS le demande, activer aussi *Réglages → Confidentialité et sécurité → Mode développeur*.

Avec un identifiant Apple gratuit, l'application cesse de s'ouvrir au bout de 7 jours.
**Réinstaller la nouvelle version par-dessus conserve les notes. Ne jamais supprimer l'application :
cela effacerait ses données.** Les pages sont visibles dans l'app Fichiers, *Sur mon iPad › Nooty*,
et l'option *Exporter la page* permet d'en garder une copie ailleurs.

## Architecture

```
Packages/NootyCore/   modèle documentaire, format d'échange, validation, identités (Swift pur, sans UIKit)
App/                  application iPad : éditeur PencilKit, stockage, fond de page, textes
AppTests/             tests de l'application (conversion PencilKit, stockage), exécutés sur simulateur
project.yml           description du projet Xcode, générée par XcodeGen
.github/workflows/    compilation, tests et production de l'IPA
design/               icône source
```

- **Encre** : PencilKit (moteur d'Apple) pour la latence, la pression, l'inclinaison et le rejet de paume.
  Il fournit aussi les outils : stylos, surligneur, gomme par trait ou partielle, lasso, règle.
- **Format** : PencilKit n'est que le moteur. Chaque trait est converti dans le modèle de Nooty
  avec toutes ses données (position, temps, taille, opacité, pression, orientation, inclinaison,
  transformation, masque de gomme), et enregistré dans un format ouvert et versionné.
- **Identifiants stables** : PencilKit ne donne pas d'identité aux traits ; Nooty les reconnaît
  d'une sauvegarde à l'autre par une empreinte (graine, date, premier point, nombre de points).
- **Enregistrement** : 0,3 s après chaque modification, sur une file de fond, en écriture atomique
  (fichier temporaire puis renommage). Enregistrement forcé quand l'application passe en arrière-plan.
  Un fichier illisible est mis de côté, jamais écrasé.
- **Annuler / rétablir** : gestionnaire d'annulation de PencilKit ; effacer la page et le test de
  charge sont aussi annulables.

### Format de page (`page.nooty.json`, schéma 1)

```json
{
  "format": "nooty.page",
  "schemaVersion": 1,
  "page": {
    "id": "UUID", "width": 595.28, "height": 841.89, "updatedAt": 1700000000000,
    "background": { "kind": "ruled", "color": "#FFFDF8FF", "lineColor": "#C9D3E0FF", "spacing": 19.84 },
    "strokes": [{
      "id": "UUID", "tool": "pen", "color": "#1D2A44FF", "createdAt": 1700000000000,
      "randomSeed": 123, "transform": [1, 0, 0, 1, 0, 0], "mask": null,
      "pointComponents": 10, "points": "base64…"
    }]
  }
}
```

Unités : points typographiques (1/72 pouce), origine en haut à gauche. Dates en millisecondes
depuis 1970. `points` : base64 de Float32 petit-boutistes, 10 par point, dans l'ordre
`x, y, temps (s depuis createdAt), largeur, hauteur, opacité, pression, orientation (rad),
inclinaison (rad), échelle secondaire`. `mask` : liste `{op: m|l|q|c|z, p: [...]}`.
À l'import, tout est validé : version, tailles (256 Mo, 200 000 traits, 100 000 points par trait),
valeurs finies, couleurs, identifiants uniques.

## Développement

Aucun Mac n'est nécessaire : chaque push déclenche le workflow `iOS`, qui exécute
`swift test` sur le cœur, les tests de l'application sur un simulateur iPad, puis produit l'IPA.

Avec un Mac (facultatif) :

```bash
brew install xcodegen
xcodegen generate
open Nooty.xcodeproj
swift test --package-path Packages/NootyCore
```

## Demandé / implémenté / testé / limites

| Fonction | État | Testé | Limites |
|---|---|---|---|
| Écriture vectorielle PencilKit (pression, inclinaison) | Implémenté | Simulateur seulement | Pencil réel à tester |
| Outils stylo, surligneur, gomme, lasso, règle, couleurs | Implémenté (sélecteur d'Apple) | Non | Interface d'Apple, pas encore la nôtre |
| Stylet seul / doigt pour dessiner | Implémenté | Non | Rejet de paume : celui d'iPadOS |
| Zoom et déplacement | Implémenté | Non | De 25 % à 600 % |
| Annuler / rétablir | Implémenté | Non | Changer de fond n'est pas annulable |
| Fonds blanc, ligné, quadrillé, pointillé | Implémenté | Non | Couleurs et espacement fixes |
| Enregistrement local, réouverture | Implémenté | Tests sur simulateur | Une modification faite moins de 0,3 s avant un arrêt brutal peut être perdue |
| Format ouvert versionné et validé | Implémenté | Tests unitaires | Un seul fichier par page, réécrit en entier |
| Conversion PencilKit ↔ format sans perte | Implémenté | Tests sur simulateur | Couleur arrondie au 1/255 |
| Export de la page | Implémenté | Non | Fichier JSON natif ; pas de PDF |
| Diagnostic et test de charge 5 000 traits | Implémenté | Non | — |
| Interface en français, structure de traduction | Implémenté | Non | Une seule langue |
| Bibliothèque, carnets, PDF, audio, transcription, IA | Non implémenté | — | Phases suivantes |

## Protocole de test sur l'iPad

Activer *Options → Afficher le diagnostic*, puis noter réussi ou échoué :

1. La pression varie entre un trait léger et un trait appuyé (ligne « Pression »).
2. L'inclinaison change quand le Pencil est penché (ligne « Inclinaison »).
3. Vingt lignes d'écriture, paume posée : aucun trait parasite.
4. Doigt pour déplacer et zoomer, Pencil pour écrire : aucune confusion sur 50 alternances.
5. Deux cents mots écrits vite : aucun trait perdu ; écriture aussi agréable qu'ailleurs.
6. Écriture de 3 mm de haut lisible.
7. *Test de charge* : écrire, zoomer et déplacer restent fluides ; noter « Enregistrement » et « Taille ».
8. Fermer l'application depuis le sélecteur d'apps juste après un trait, rouvrir : le trait est là.
9. Réinstaller par Sideloadly : les notes sont toujours là.
10. Mode avion : tout fonctionne.

## Dépendances et licences

Aucune bibliothèque tierce dans l'application : uniquement les frameworks d'Apple
(UIKit, SwiftUI, PencilKit, Foundation). Outils de compilation : XcodeGen (MIT),
installé sur le Mac de GitHub au moment de la compilation.

## Confidentialité

Aucun appel réseau, aucune télémétrie, aucun compte. Les notes restent sur l'iPad.
