# Nooty

Application personnelle de prise de notes au stylet, local-first, installable sur iPad
(application Web progressive). Code, format et identité visuelle indépendants.

**État : phase 0, prototype stylet.** Une seule page, pour valider l'écriture sur le matériel
réel avant de construire la bibliothèque et les carnets.

## Commandes

Prérequis : Node.js 22.

```bash
npm ci            # installation
npm run dev       # développement, http://localhost:5173
npm test          # tests unitaires
npm run build     # vérification des types + build de production dans dist/
npm run preview   # sert dist/ sur http://localhost:4173
npm run e2e       # test navigateur sur le build (nécessite le paquet playwright et Chromium)
```

## Installation sur l'iPad

1. Dépôt GitHub public, puis *Settings → Pages → Source : GitHub Actions*.
2. Chaque push déclenche les tests, le build et la publication.
3. Sur l'iPad, ouvrir l'adresse publiée dans Safari, puis *Partager → Sur l'écran d'accueil*.
4. Lancer Nooty depuis l'icône : l'application fonctionne ensuite hors connexion.

L'installation sur l'écran d'accueil est nécessaire : Safari peut purger le stockage d'un
site simplement visité. Les notes ne quittent jamais l'appareil.

## Architecture

```
src/core/      modèle documentaire, géométrie, lissage, commandes, sérialisation (pur, sans DOM)
src/ink/       capture des pointeurs et rendu canvas
src/storage/   stockage de travail IndexedDB
src/i18n/      catalogue de messages (français)
src/app/       interface du prototype
tests/         tests unitaires (Vitest)
e2e/           scénario navigateur (Playwright)
```

- Coordonnées en points typographiques (1/72 pouce), indépendantes du zoom et de l'écran.
- Les traits sont des données : points `x, y, t, pression, tiltX, tiltY`, jamais une image.
- Deux calques : contenu validé et trait en cours. Écrire ne redessine que le trait en cours ;
  annuler ou gommer ne redessine que la zone touchée.
- Chaque action est une commande annulable ; une nouvelle action vide la pile de rétablissement
  (200 actions conservées).
- Chaque trait est une entrée IndexedDB. Une sauvegarde écrit seulement la différence, dans une
  transaction unique, immédiatement après chaque action.

## Demandé / implémenté / testé / limites

| Fonction | État | Testé | Limites |
|---|---|---|---|
| Stylo vectoriel sensible à la pression | Implémenté | Unitaire + navigateur (souris) | Stylet réel non testé |
| Capture stylet, souris, tactile, points coalescés | Implémenté | Souris seulement | Inclinaison enregistrée, pas encore utilisée au rendu |
| Prédiction du trait | Implémenté, optionnel | Non | Dépend du navigateur ; désactivée par défaut |
| Rejet de paume | Partiel | Non | Tactile ignoré pendant et 400 ms après le stylet ; le reste dépend d'iPadOS |
| Doigt = navigation, stylet = dessin | Implémenté | Non (tactile non simulé) | Option « dessiner au doigt » |
| Zoom et déplacement | Implémenté | Unitaire + navigateur (molette) | Pincement non testé automatiquement |
| Gomme par trait | Implémenté | Unitaire + navigateur | Gomme partielle non implémentée |
| Annuler / rétablir | Implémenté | Unitaire + navigateur | Le changement de fond n'est pas annulable |
| Fonds blanc, ligné, quadrillé, pointillé | Implémenté | Visuel | Couleurs et espacement non réglables dans l'interface |
| Sauvegarde locale et réouverture | Implémenté | Unitaire + navigateur | Un trait tracé dans les millisecondes précédant un arrêt brutal peut être perdu, sans corruption |
| Hors connexion (service worker) | Implémenté | Navigateur (Chromium) | Non testé sur Safari |
| Sérialisation JSON validée, versionnée | Implémenté | Unitaire | Pas encore d'export `.nooty` dans l'interface |
| Test de charge 5 000 traits | Implémenté | Navigateur | Mesures faites sans GPU, non représentatives |
| Interface en français, i18n, clavier, focus | Implémenté | Partiel | Une seule langue ; pas d'audit d'accessibilité |
| Bibliothèque, carnets multipages | Non implémenté | — | Phase 1 |
| Surligneur, lasso, texte, images, PDF, audio, OCR, IA, synchronisation | Non implémenté | — | Phases 2 à 5 |

## Protocole de test sur l'iPad

Activer *Options → Afficher le diagnostic*, puis noter réussi ou échoué :

1. « Pointeur » affiche `pen` et « Pression » varie selon l'appui.
2. Vingt lignes d'écriture, paume posée : aucun trait parasite.
3. Cinquante alternances doigt (déplacer, zoomer) / stylet (écrire) sans confusion.
4. Deux cents mots écrits vite : aucun trait perdu ou tronqué ; relever « Points/s » et « Coalescés ».
5. Filmer au ralenti dix traits rapides et estimer l'écart entre la pointe et l'encre ; comparer avec et sans prédiction.
6. Écriture de 3 mm de haut : lisible, non déformée.
7. *Test de charge* : écrire, zoomer et déplacer avec 5 000 traits ; relever « Rendu complet » et « Image la plus lente ».
8. Tracé identique à 100 % et 400 %, puis après fermeture et réouverture.
9. Changer d'application en plein trait : pas de trait fantôme au retour.
10. Mode avion : l'application s'ouvre, les notes sont là, écrire fonctionne.
11. « Stockage persistant » : relever la valeur affichée.

## Dépendances et licences

Aucune dépendance à l'exécution. Outils de développement :

| Paquet | Version | Licence |
|---|---|---|
| vite | 8.3.7 | MIT |
| vitest | 5.1.0 | MIT |
| typescript | 6.0.3 | Apache-2.0 |
| fake-indexeddb | 6.2.8 | Apache-2.0 |
| @types/node | 22.20.5 | MIT |

## Confidentialité

Aucun appel réseau en dehors du chargement initial de l'application. Aucune télémétrie,
aucun compte, aucune clé.
