# Tests manuels avec le clavier

Ces vérifications demandent une main sur le clavier. Elles ne sont **pas**
couvertes par `make test` et ne doivent pas être déclarées réussies sans avoir
été exécutées. Colonne « Résultat » : à remplir (`OK`, `KO` + observation, date).

## Préparation

1. Installer : `bash scripts/install.sh`, puis `magictrackpointctl permissions`
   et accorder les deux autorisations dans les réglages ouverts.
2. `magictrackpointctl status` : `state=running`, `input_monitoring=granted`,
   `accessibility=granted`, une ligne `device.N=bluetooth sensitivity:applied
   preferred_scrolling:applied`.
3. Journal détaillé : `plutil -replace logging.level -string debug
   ~/.config/magictrackpoint/config.plist`, puis `magictrackpointctl reload`, puis
   dans un second terminal `magictrackpointctl log`.

Chaque geste produit une ligne `gesture start`, des lignes `wheel raw h=… v=…`,
puis `gesture end: travel=… scrolled=… click=… pointer-motion-reports=…`.

## Hypothèses à trancher en premier (architecture §11)

| # | Manipulation | Ce qu'il faut regarder | Résultat |
|---|---|---|---|
| H2/H3 | Bouton central tenu, pousser le TrackPoint vers le haut puis vers la droite | Des `wheel raw` avec `v≠0` puis `h≠0`, et `held=yes` | OK 2026-11-22 (Bluetooth) |
| H3 | Appui bref sur le bouton central | `gesture start` puis `gesture end` ; noter la source (`button 3` ou `vendor`) | OK 2026-11-22, source `vendor` |
| H4 | Bouton central tenu, pousser fort | Le curseur ne doit pas bouger ; `pointer-motion-reports=0` | OK 2026-11-22 (55 gestes, 0 rapport de mouvement) |
| H1 | 20 clics centraux sur un lien dans Safari | Exactement 20 nouveaux onglets, jamais 40 | OK 2026-11-22 (un onglet par clic) |
| H6 | Défiler vers le bas dans une page longue | Le contenu suit le sens habituel du trackpad | OK 2026-11-22 |
| H8 | Défiler vers le haut puis vers le bas, même force | Même vitesse dans les deux sens | KO 2026-11-22 (haut/gauche plus lents) ; corrigé (octet signé) ; OK 2026-11-22 après correction |
| Accélération | Pousser doucement puis fort, bouton tenu | Le défilement accélère nettement avec la force ; `scroll.acceleration` à 0 le rend linéaire | OK 2026-11-22 (`acceleration` = 1, défaut conservé) |

## Fonctionnels

| Test | Manipulation | Attendu | Résultat |
|---|---|---|---|
| Sensibilité | `sensitivity` à 1, `reload`, déplacer ; puis 9 | Différence nette de vitesse du curseur | |
| Sensibilité par défaut | Supprimer la clé, `reload` | Même vitesse qu'à 7 | |
| Clic central | Appui-relâché immobile sur un lien | Un onglet en arrière-plan ; `click=yes` || OK 2026-11-22 (1.0.1) |
| Défilement vertical | Bouton tenu + haut/bas dans une page longue | Défilement fluide, sans à-coups || OK 2026-11-22 (1.0.1) |
| Défilement horizontal | Bouton tenu + gauche/droite dans un tableur ou une image large | Défilement horizontal || OK 2026-11-22 (1.0.1) |
| Horizontal désactivé | `horizontal` à faux, `reload`, geste horizontal | Rien ne défile, **et pas de clic** au relâchement | |
| Sous le seuil | Appui avec une très légère pression latérale | `travel` < 3, `scrolled=no`, un seul clic | |
| Défilement puis relâché | Défiler sur un lien, relâcher dessus | Aucun onglet ouvert ; `click=no` | |
| Pas de défilement sans bouton | Bouger le TrackPoint sans bouton | Le curseur bouge, aucun défilement | |
| Vitesse | `speed` à 0.5 puis 2, `reload` | Défilement deux fois plus lent / rapide | |
| Clic désactivé | `click_if_no_scroll` à faux | Appui bref : rien | |
| Défilement désactivé | `scroll.enabled` à faux | Comportement natif du clavier, `accessibility=not-needed` | |
| Rechargement | Modifier un réglage puis `reload` | Pris en compte sans redémarrage | |
| Déconnexion / reconnexion | Éteindre puis rallumer le clavier | `devices=0` puis `devices=1`, sensibilité réappliquée | |
| Sortie de veille | Mettre le Mac en veille 2 min, réveiller | Sensibilité et défilement fonctionnent sans intervention | |
| Bluetooth ↔ USB | Si le récepteur est disponible : basculer | Le nouveau transport est configuré | |

## Robustesse

| Test | Manipulation | Attendu | Résultat |
|---|---|---|---|
| Déconnexion pendant un défilement | Bouton tenu, défiler, éteindre le clavier | Le défilement s'arrête, aucun clic, aucun bouton bloqué (vérifier avec la souris) | |
| Daemon tué bouton tenu | Bouton tenu, `pkill -9 magictrackpointd`, relâcher | Aucun bouton bloqué ; launchd relance le daemon après 30 s maximum | |
| Arrêt propre | `magictrackpointctl stop` | Plus de processus ; pas de relance | |
| Perte des autorisations | Désactiver l'Accessibilité, puis appuyer une fois sur le bouton central | Dès cet appui : `status` montre `accessibility=MISSING`, le clic central natif fonctionne, pas de défilement ; réactiver → reprise en 5 s au plus | |
| Commande `permissions` | Une autorisation désactivée, `magictrackpointctl permissions` | Réglages s'ouvre sur le bon panneau, sortie 3 ; après activation, nouvelle commande → `All permissions granted.`, sortie 0 | OK 2026-11-22 (Surveillance de l'entrée et Accessibilité, premier octroi) |
| Surveillance de l'entrée sans redémarrage | L'activer pendant que le daemon tourne, attendre 10 s, `status` | Constaté : reste `MISSING` jusqu'au redémarrage (macOS 27) ; l'Accessibilité, elle, passe à `granted` | Constaté 2026-11-22 |
| Clavier absent au démarrage | Clavier éteint, `restart`, allumer | Configuré à la connexion | |
| Configuration invalide | Mettre `sensitivity` à 12, `reload` | Erreur dans le journal et `status`, valeur 7 appliquée | |
| Configuration absente | Renommer le fichier, `reload` | Valeurs par défaut | |
| Redémarrages répétés | 20 × `magictrackpointctl restart` | Toujours fonctionnel | |
| Souris externe + trackpad | Défilement et clic central de la souris, défilement du trackpad, pendant et hors d'un geste TrackPoint | Trackpad toujours inchangé ; souris : molette et clic central ignorés pendant le geste (limite connue), inchangés dès 250 ms après le relâché || OK 2026-11-22 (1.0.1) : trackpad et souris externe fonctionnent ; le cas « souris pendant un geste » n'a pas été noté |
| Molette juste après un geste | Défiler au TrackPoint, relâcher, tourner aussitôt la molette d'une souris externe | Le premier cran de molette est pris en compte (aucun « dû » résiduel) || OK 2026-11-22 (1.0.1) |
| Configuration illisible | Écrire `scroll.enabled` = `"oui"` (chaîne), `reload` | Erreur dans `status`, `scroll=off`, clavier en mode natif | |

## Performances

| Mesure | Méthode | Résultat |
|---|---|---|
| CPU au repos | `top -l 6 -s 10 -pid $(pgrep -x magictrackpointd) -stats cpu,mem` sans toucher le clavier | |
| Mémoire | `ps -o rss= -p $(pgrep -x magictrackpointd)` au démarrage, puis après 1 h d'usage | |
| Fuites après reconnexions | RSS avant et après 10 déconnexions/reconnexions | |
| Latence | Impression subjective du clic et du défilement par rapport au daemon d'origine | |
| Comparaison | Mêmes mesures avec TrackPointD d'origine, si réinstallé temporairement | |

## Touches spéciales (1.1.0)

| Test | Manipulation | Attendu | Résultat |
|---|---|---|---|
| Micro | F4, parler en regardant *Réglages → Son → Entrée*, F4 | Son *Pop*, jauge à plat ; son *Tink*, jauge active ; `microphone=` suit | OK 2026-11-23 |
| Bluetooth | F10, puis F10 | Centre de contrôle sur la liste Bluetooth, puis entièrement fermé ; le Bluetooth reste actif | OK 2026-11-23 (fermeture complète après correction) |
| Capture | Impr. écran | Fenêtre de capture (⇧⌘5, CleanShot) | OK 2026-11-23 |
| Rechargement juste après démarrage | `restart` puis `reload` aussitôt | Le daemon reste actif (`runs = 1`) | OK 2026-11-23 |
| Touches désactivées | `keys.*` à faux, `reload` | Aucune action | |
| Récepteur USB | Mêmes touches en USB | Mêmes actions | |
