# Nooty

Application iPad personnelle de prise de notes à l'Apple Pencil. Native (Swift, UIKit, PencilKit),
local-first, sans compte ni abonnement. Code, format de fichier et identité visuelle indépendants.

**État : version 0.2.** Bibliothèque, blocs-notes multipages, modèles de papier (dont Seyès) et
barre d'outils propre à Nooty. L'audio, la transcription, les images, le PDF et l'IA ne sont pas
encore là.

## Installer sur l'iPad (sans Mac)

L'application est compilée par les Mac de GitHub Actions (gratuit pour un dépôt public),
puis signée et installée depuis un PC Windows avec Sideloadly.

1. Onglet **Actions** du dépôt → dernière exécution réussie du workflow **iOS**.
2. En bas de la page, section *Artifacts* : télécharger **Nooty-ipa**, puis le dézipper pour obtenir `Nooty.ipa`.
3. iPad branché au PC, ouvrir Sideloadly, glisser `Nooty.ipa`, saisir l'identifiant Apple, lancer.
4. Première fois seulement, sur l'iPad, dans cet ordre :
   - *Réglages → Confidentialité et sécurité*, tout en bas, section *Sécurité* → **Mode développeur** → activer,
     redémarrer, puis confirmer *Activer*. Cette option n'apparaît qu'**après** une première installation
     par Sideloadly, et seulement sous iPadOS 16 ou plus récent.
   - *Réglages → Général → VPN et gestion de l'appareil* → toucher l'identifiant Apple → *Faire confiance*.

Avec un identifiant Apple gratuit, l'application cesse de s'ouvrir au bout de 7 jours.
**Réinstaller la nouvelle version par-dessus conserve les notes. Ne jamais supprimer l'application :
cela effacerait ses données.** Les pages sont visibles dans l'app Fichiers, *Sur mon iPad › Nooty*,
et l'option *Exporter la page* permet d'en garder une copie ailleurs.

## Architecture

```
Packages/NootyCore/   modèle, formats de fichier, validation, bibliothèque, disposition des pages (Swift pur)
App/                  application iPad : bibliothèque, éditeur, outils, stockage, papier, textes
AppTests/             tests de l'application (conversion PencilKit, stockage), exécutés sur simulateur
project.yml           description du projet Xcode, générée par XcodeGen
.github/workflows/    compilation, tests et production de l'IPA
design/               icône source
```

- **Encre** : PencilKit (moteur d'Apple) pour la latence, la pression, l'inclinaison et le rejet de paume.
  La palette d'Apple n'est plus affichée : les outils sont pilotés par la barre de Nooty.
- **Format** : PencilKit n'est que le moteur. Chaque trait est converti dans le modèle de Nooty
  avec toutes ses données et enregistré dans un format ouvert et versionné.
- **Pages** : toutes les pages d'un bloc-notes défilent sur une seule surface d'écriture. Un trait
  appartient à la page qui contient son centre ; il est enregistré dans le repère de cette page.
- **Identifiants stables** : PencilKit ne donne pas d'identité aux traits ; Nooty les reconnaît
  d'une sauvegarde à l'autre par une empreinte (graine, date, premier point, nombre de points).
- **Enregistrement** : 0,3 s après chaque modification, sur une file de fond. Seules les pages
  modifiées sont réécrites, en écriture atomique. Enregistrement forcé à la mise en arrière-plan
  et à la fermeture du bloc-notes. Un fichier illisible est mis de côté, jamais écrasé.
- **Annuler / rétablir** : gestionnaire d'annulation de PencilKit. Ajouter ou supprimer une page
  vide cet historique.

### Fichiers (dossier Documents de l'application, visible dans l'app Fichiers)

```
Bibliotheque/bibliotheque.json              index : dossiers, blocs-notes, favoris, corbeille
Bibliotheque/carnets/<id>/carnet.json       manifeste : ordre, taille et papier des pages
Bibliotheque/carnets/<id>/pages/<id>.json   contenu d'une page
Bibliotheque/carnets/<id>/miniature.png     aperçu, reconstructible
```

Les trois formats (`nooty.library`, `nooty.notebook`, `nooty.page`) portent un nom de format et
une version de schéma, et sont validés à la lecture. L'index est reconstructible à partir des
dossiers de blocs-notes.

Page : unités en points typographiques (1/72 pouce), origine en haut à gauche, dates en
millisecondes depuis 1970. `points` : base64 de Float32 petit-boutistes, 10 par point, dans l'ordre
`x, y, temps (s depuis createdAt), largeur, hauteur, opacité, pression, orientation (rad),
inclinaison (rad), échelle secondaire`. `mask` : liste `{op: m|l|q|c|z, p: [...]}`.
Limites à l'import : 256 Mo, 200 000 traits, 100 000 points par trait, 5 000 pages.

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

« Simulateur » : tests automatiques sur simulateur iPad. Rien n'a été vérifié sur un iPad réel
tant que le protocole ci-dessous n'est pas fait.

| Fonction | État | Testé | Limites |
|---|---|---|---|
| Bibliothèque : dossiers et sous-dossiers, blocs-notes | Implémenté | Unitaire + simulateur (stockage) | Affichage en grille seulement |
| Créer, renommer, déplacer, dupliquer, couleur | Implémenté | Unitaire | Dupliquer : blocs-notes seulement |
| Corbeille, restauration, suppression définitive | Implémenté | Unitaire + simulateur | — |
| Favoris, tri par nom, modification, création | Implémenté | Unitaire | — |
| Recherche, documents récents, import, export | Non implémenté | — | — |
| Nouveau bloc-notes : nom, modèle, couleur du papier | Implémenté | Non | Format A4 portrait uniquement |
| Papiers Seyès, ligné, quadrillé, pointillé, vierge | Implémenté | Non | Espacements fixes |
| Pages : ajouter avant, après, à la fin ; supprimer | Implémenté | Unitaire (disposition) | Pas de réorganisation ni de miniatures de pages |
| Modèle indépendant par page | Implémenté | Non | — |
| Reprise à la dernière page consultée | Implémenté | Unitaire (format) | Le zoom n'est pas mémorisé |
| Stylos bille, plume, pinceau ; 3 épaisseurs ; 5 couleurs modifiables | Implémenté | Simulateur (outils valides) | Épaisseurs à régler d'après vos essais |
| Surligneur | Implémenté | Non | — |
| Gomme par trait entier ou de précision, 3 tailles | Implémenté | Non | — |
| Lasso : déplacer, copier, supprimer | Implémenté (PencilKit) | Non | Pas de redimensionnement ni de rotation |
| Stylet seul par défaut, option « dessiner au doigt » | Implémenté | Non | Rejet de paume : celui d'iPadOS |
| Annuler / rétablir | Implémenté | Non | Historique vidé quand on ajoute ou supprime une page |
| Enregistrement par page, récupération de fichiers abîmés | Implémenté | Simulateur | Une modification faite moins de 0,3 s avant un arrêt brutal peut être perdue |
| Conversion PencilKit ↔ format sans dérive | Implémenté | Simulateur | Inclinaison stable à 0,001° près |
| Miniature de couverture | Implémenté | Non | Première page seulement |
| Onglets, formes, texte, images, PDF | Non implémenté | — | Versions suivantes |
| Audio, export MP3, transcription, IA | Non implémenté | — | Versions suivantes |

## Protocole de test sur l'iPad

1. Créer un dossier, puis un bloc-notes Seyès dedans ; le renommer, le mettre en favori.
2. Écrire avec les trois types de stylo et les trois épaisseurs ; dire lequel se rapproche le plus de votre réglage Goodnotes.
3. Vingt lignes d'écriture, paume posée : aucun trait parasite. Doigt pour déplacer et zoomer.
4. Surligneur, gomme « trait entier », gomme « précision », lasso.
5. Changer une couleur : toucher deux fois la même pastille.
6. Ajouter une page après, avant et à la fin ; écrire sur chacune ; supprimer celle du milieu : les autres gardent leur contenu.
7. Revenir à la bibliothèque : la miniature montre la première page.
8. Fermer l'application depuis le sélecteur d'apps juste après un trait, rouvrir : le trait est là, à la même page.
9. Mettre le bloc-notes à la corbeille, le restaurer.
10. Réinstaller par Sideloadly : tout est encore là. Mode avion : tout fonctionne.

## Dépendances et licences

Aucune bibliothèque tierce dans l'application : uniquement les frameworks d'Apple
(UIKit, SwiftUI, PencilKit, Foundation). Outils de compilation : XcodeGen (MIT),
installé sur le Mac de GitHub au moment de la compilation.

## Confidentialité

Aucun appel réseau, aucune télémétrie, aucun compte. Les notes restent sur l'iPad.
