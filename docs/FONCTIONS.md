# Inventaire fonctionnel

Référence : les fonctions publiques de Goodnotes 6. Nooty en reprend les fonctions avec sa propre
interface. État : ✅ fait · 🟡 partiel · ⬜ non fait · ⛔ hors de portée à coût nul.
« Simulateur » : couvert par les tests automatiques ou les captures d'écran du simulateur.
Rien n'a été vérifié sur un iPad réel avec le Pencil, le micro ou l'appareil photo.

## 1. Bibliothèque

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Documents, Favoris, Corbeille | ✅ | Unitaire, simulateur | — |
| Dossiers et sous-dossiers, couleur | ✅ | Unitaire | — |
| Créer, renommer, déplacer, dupliquer, supprimer, restaurer | ✅ | Unitaire, simulateur | — |
| Tri par modification, création, nom | ✅ | Unitaire | — |
| Vue grille et vue liste | ✅ | Non | — |
| Recherche : titres, texte, PDF, écriture reconnue, transcriptions | ✅ | Unitaire (index) | L'écriture est indexée à la fermeture du bloc-notes ou à l'ouverture de la recherche |
| Nouveau : bloc-notes, tableau blanc, document texte, dossier | ✅ | Simulateur | — |
| Importer PDF, images, fichiers .nooty ; scanner ; photos | ✅ | Unitaire (PDF, .nooty) | Scan et photos non testés |
| Verrouillage par Face ID ou code | ✅ | Non | Sans code configuré sur l'iPad, le verrou ne protège pas |
| Onglets des documents ouverts | ✅ | Non | Limités à la session en cours |
| Sélection multiple | ⬜ | — | — |
| Partage par lien, Marketplace, widgets | ⛔ | — | Serveurs ou signature payante nécessaires |

## 2. Création

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Nom, modèle, couleur du papier | ✅ | Simulateur | — |
| Seyès, ligné, quadrillé, pointillé, vierge | ✅ | Unitaire | Espacements fixes |
| Formats A4, A5, A3, Lettre US, carré ; portrait ou paysage | ✅ | Unitaire | — |
| Couvertures illustrées | 🟡 | — | Couleur de tranche et miniature de la première page |
| Modèles importés (PDF ou image) | 🟡 | — | Possible en important un PDF ; pas de bibliothèque de modèles |

## 3. Pages

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Défilement vertical continu, zoom | ✅ | Simulateur | Pas de défilement horizontal |
| Ajouter avant, après, à la fin, avec un autre modèle | ✅ | Simulateur | — |
| Pages depuis Photos, scan, appareil photo, PDF | ✅ | Unitaire (PDF) | — |
| Panneau des miniatures, réorganisation par appui long | ✅ | Non | — |
| Dupliquer, effacer, supprimer, changer modèle et couleur | ✅ | Non | — |
| Copier une page dans un autre bloc-notes | ✅ | Non | — |
| Signets, plan, aller à la page | ✅ | Unitaire (format) | — |
| Reprise à la dernière page | ✅ | Unitaire | Le zoom n'est pas mémorisé |
| Rotation d'une page | ⬜ | — | — |

## 4. Outils

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Stylo bille, plume, pinceau ; crayon ; surligneur | ✅ | Simulateur | Moteur d'Apple (PencilKit) |
| Trois épaisseurs réglables, cinq couleurs modifiables par outil | ✅ | Simulateur | — |
| Gomme précision, standard, trait entier ; trois tailles | ✅ | Simulateur | — |
| Lasso : déplacer, copier, couper, supprimer des traits | ✅ | Non | Fourni par PencilKit ; ne sélectionne pas les images |
| Sélection d'image ou de texte : déplacer, redimensionner, pivoter, dupliquer, ordre | ✅ | Non | Un élément à la fois |
| Formes : segment, flèche, rectangle, ellipse, triangle, losange | ✅ | Unitaire | Contour seulement, sans remplissage |
| Dessiner et maintenir pour redresser une forme | ✅ | Unitaire (reconnaissance) | — |
| Zone de texte : police, taille, couleur, gras, italique, souligné, alignement | ✅ | Simulateur | Style uniforme dans une zone |
| Note repositionnable | ✅ | Non | — |
| Ruban de masquage, tout révéler ou masquer | ✅ | Unitaire (format) | — |
| Pointeur laser | ✅ | Non | Visible sur l'iPad seulement |
| Annuler, rétablir | ✅ | Non | Vidés quand on ajoute, déplace ou supprime une page |
| Stabilisation du trait | ⛔ | — | Non exposée par PencilKit |
| Règle | 🟡 | — | Celle de PencilKit n'est pas affichée sans sa palette |
| Personnalisation de la barre d'outils | ⬜ | — | — |

## 5. Images et éléments

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Insérer depuis Photos, appareil photo, Fichiers, presse-papiers | ✅ | Non | — |
| Recadrer | ✅ | Non | Rectangulaire |
| Mes éléments (images réutilisables) | ✅ | Non | Images seulement |

## 6. PDF et export

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Import multipage, tailles et rotations différentes | ✅ | Unitaire | — |
| PDF protégé ou endommagé : message clair | ✅ | Non | — |
| Recherche dans le texte natif | ✅ | Non | — |
| Liens internes et sélection de texte du PDF | ⬜ | — | — |
| Export PDF (tout, sans papier, une page), image PNG, impression | ✅ | Unitaire (PDF) | Encre rastérisée en haute résolution : non vectorielle |
| Format natif .nooty (export et import sans perte, audio compris) | ✅ | Unitaire | — |

## 7. Audio

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Enregistrer, pause, reprise, plusieurs enregistrements | ✅ | Non | — |
| Enregistrement en arrière-plan | ✅ | Non | — |
| Lecture, vitesse 0,5× à 2×, sauts de 15 s, curseur | ✅ | Non | — |
| Rejouer l'écriture au fil de l'audio | ✅ | Unitaire (correspondance des temps) | — |
| Toucher un trait pour entendre le passage | ✅ | Non | — |
| Transcription en direct, horodatée | ✅ | Non | Moteur d'Apple ; qualité à vérifier en cours réel |
| Questions entendues et réponse par l'IA | ✅ | Non | Détection par point d'interrogation ; IA facultative |
| Résumé | ✅ | Non | Exige l'IA |
| Export M4A et MP3 | ✅ | Simulateur (MP3) | — |

## 8. Révision et IA

| Fonction | État | Vérifié | Limites |
|---|---|---|---|
| Cartes recto-verso, séances, répétition espacée (Leitner) | ✅ | Unitaire | — |
| Génération de cartes par l'IA | ✅ | Non | Exige l'IA |
| Convertir l'écriture en texte | ✅ | Non | Reconnaissance d'Apple, qualité variable |
| Assistant : question, résumé, à faire, traduction, reformulation | ✅ | Non | Gemini avec clé personnelle |
| Aide en mathématiques (lecture de la page, LaTeX, explication) | ✅ | Non | Résultat non garanti |
| Correction de l'écriture manuscrite | ⛔ | — | Modèles propriétaires |

## 9. Synchronisation

| Fonction | État | Raison |
|---|---|---|
| iCloud | ⛔ | Indisponible avec une signature gratuite |
| Collaboration, commentaires | ⛔ | Serveur nécessaire |
| Sauvegarde de toute la bibliothèque vers un dossier choisi | ✅ | Manuelle, depuis les réglages |

## 10. Réglages

| Fonction | État |
|---|---|
| Thème système, clair, sombre | ✅ |
| Dessiner au doigt, redresser les formes | ✅ |
| Transcription : activation, serveurs d'Apple, langue | ✅ |
| IA : activation, clé, modèle, accord avant chaque envoi | ✅ |
| Espace utilisé, sauvegarde, licences | ✅ |
