# Nooty

Application iPad personnelle de prise de notes à l'Apple Pencil. Native (Swift, UIKit, PencilKit),
local-first, sans compte ni abonnement. Code, format de fichier et identité visuelle indépendants.

**État : version 1.0.** Bibliothèque, blocs-notes, tableaux blancs et documents texte ; tous les
outils d'écriture ; images, textes, formes, rubans ; PDF ; audio synchronisé avec transcription et
export MP3 ; recherche ; cartes de révision ; assistant IA facultatif. Détail et limites :
[`docs/FONCTIONS.md`](docs/FONCTIONS.md).

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

Le tableau complet, fonction par fonction, est dans [`docs/FONCTIONS.md`](docs/FONCTIONS.md).
« Simulateur » signifie : tests automatiques et captures d'écran sur simulateur iPad.
Rien de ce qui demande le Pencil, le micro, l'appareil photo ou le réseau n'a été vérifié sur un
iPad réel.

## Protocole de test sur l'iPad

1. **Bibliothèque** : créer un dossier, un bloc-notes Seyès A4, un tableau blanc, un document texte ;
   renommer, mettre en favori, verrouiller, passer en vue liste, rechercher un titre.
2. **Écriture** : stylo (bille, plume, pinceau), crayon, surligneur, trois épaisseurs, réglage fin en
   touchant deux fois une épaisseur, couleurs en touchant deux fois une pastille.
3. **Gommes** : précision, standard, trait entier.
4. **Formes** : outil Formes ; puis avec le stylo, dessiner un rectangle et maintenir le Pencil immobile.
5. **Lasso** : entourer des traits et les déplacer ; toucher une image ou un texte pour le sélectionner.
6. **Texte** : outil Texte, toucher la page, écrire ; gras, taille, couleur ; note repositionnable.
7. **Images** : Insérer › Photos ; déplacer, redimensionner, pivoter, recadrer ; ajouter à « Mes éléments ».
8. **Ruban** : tracer un ruban sur une définition, le toucher pour révéler.
9. **Pages** : panneau des pages, réorganiser par appui long, dupliquer, signet, titre de plan,
   copier dans un autre bloc-notes, aller à la page en touchant « 1 sur N ».
10. **PDF** : importer un PDF de cours, annoter, exporter en PDF ; scanner une feuille.
11. **Audio** : enregistrer en écrivant, ouvrir la transcription, arrêter ; lire, changer la vitesse,
    activer « Rejouer l'écriture », toucher un mot écrit ; exporter en MP3 et l'écouter ailleurs.
12. **Recherche** : rechercher un mot écrit à la main, un mot du PDF, un mot prononcé.
13. **Cartes** : créer deux cartes, faire une séance de révision.
14. **IA** (facultatif) : saisir une clé Gemini dans Réglages, demander un résumé, poser une question.
15. **Robustesse** : fermer l'application juste après un trait, rouvrir ; réinstaller par Sideloadly ;
    mode avion.

## Dépendances et licences

- Frameworks d'Apple : UIKit, SwiftUI, PencilKit, PDFKit, Vision, VisionKit, Speech, AVFoundation,
  LocalAuthentication.
- [shine](https://github.com/toots/shine), encodeur MP3, licence GNU LGPL 2, sources incluses dans
  `Packages/Shine` (voir son `README.md`).
- Outil de compilation : XcodeGen (MIT), installé sur le Mac de GitHub.
- Facultatif : API Gemini de Google pour l'IA, avec la clé de l'utilisateur.

## Confidentialité

- Aucune télémétrie, aucun compte. Les notes restent sur l'iPad.
- La transcription se fait sur l'iPad quand il en est capable ; l'envoi aux serveurs d'Apple n'a
  lieu que si l'option est activée dans les réglages.
- L'IA est désactivée par défaut. Avant chaque envoi, l'application indique ce qui part et à qui.
  La clé est rangée dans le trousseau de l'iPad, jamais dans le code.
