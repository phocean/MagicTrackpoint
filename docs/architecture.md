# MagicTrackpoint — architecture et décisions

Ce document fixe les choix techniques et leur justification. Licence : GNU GPL
version 3 ou ultérieure ; le code est entièrement propre au projet (§13).

## 1. Vue d'ensemble

```text
launchd (LaunchAgent utilisateur, session Aqua)
  └─ magictrackpointd            un processus, une boucle d'exécution, ~770 lignes
       ├─ IOHIDManager            17EF:60EE (USB) et 17EF:60E1 (Bluetooth) uniquement
       │    ├─ connexion          → SetReport : sensibilité (0x02), Preferred Scrolling (0x09)
       │    ├─ rapport 0x16       → défilement (unités du firmware)
       │    └─ bouton central     → bouton HID 3, FFA0:FB (USB), rapport 0x15 (BLE)
       ├─ 2 event taps HID        → retenue du clic central natif, molette native BLE
       ├─ IORegisterForSystemPower → réapplication au réveil
       └─ signaux                 SIGHUP = rechargement, SIGTERM = arrêt propre

magictrackpointctl (script shell) → launchctl + fichier d'état
~/.config/magictrackpoint/config.plist
```

Le code se répartit en deux fichiers :

- `src/mtp_core.h` : logique pure et déterministe (configuration, rapports HID,
  machine à états du geste, décision de filtrage), testée par `tests/core_test.m`.
- `src/magictrackpointd.m` : effets système (IOKit, CoreGraphics, launchd, journal).

## 2. Matériel réellement pris en charge

Établi sur ce Mac le 2026-11-21 :

| Élément | Valeur |
|---|---|
| Modèle | ThinkPad TrackPoint Keyboard II |
| Connexion utilisée | Bluetooth LE, `17EF:60E1` |
| Récepteur USB `17EF:60EE` | Même protocole, **non vérifié ici** |
| Compact Keyboard `17EF:6048` | **Retiré** : aucun réglage matériel possible, jamais vérifié |

Descripteur HID Bluetooth lu dans l'IORegistry (lecture seule) :

| Rapport | Type | Contenu |
|---|---|---|
| `0x01` | Entrée | Clavier standard (touches) |
| `0x02` | Entrée | Souris standard : boutons 1–3, X, Y, molette verticale |
| `0x05` | Entrée | Touches Lenovo (ignoré) |
| `0x15` | Entrée, vendeur | 8 octets ; bit `0x04` de l'octet 2 = bouton central |
| `0x16` | Entrée, vendeur | 2 octets : horizontal, vertical (défilement du firmware) |
| `0x18` | Sortie, vendeur | Configuration : `18 commande valeur` |

Conséquence : en Bluetooth, macOS reçoit **nativement** le bouton central et la
molette verticale (rapport `0x02`). Il faut donc les neutraliser pendant un geste
TrackPoint, sinon le défilement serait doublé et un clic parasite émis.

## 3. Défilement : le firmware fait la conversion

Quand la commande `0x09` (Preferred Scrolling) vaut 1, c'est **le clavier** qui
transforme le mouvement du TrackPoint, bouton central tenu, en rapports `0x16`.
Le daemon ne convertit jamais un mouvement de curseur en défilement.

Raison : macOS n'offre aucune API publique pour savoir quel périphérique a
produit un événement de mouvement. Convertir le mouvement en défilement
obligerait à deviner l'origine (le projet d'origine utilisait une fenêtre de
50 ms) et risquerait d'affecter la souris externe ou le trackpad.

Rendu :

- un rapport de `u` unités = |u|^(1 + `acceleration`) × 10 pixels × `speed`
  (10 px = une « ligne » Quartz, mesuré) ;
- événements en **pixels**, émis à chaque rapport, sans minuterie ni lot ; les
  restes sous le pixel sont reportés pour ne rien perdre aux vitesses lentes ;
- accélération **par la force** : le firmware mesure déjà l'appui (1 unité par
  rapport pour un appui léger, 3 à 4 pour un appui fort, mesuré) ; la courbe
  s'applique à cette valeur, donc sans dépendre du temps ni du rythme des
  rapports. Défaut 1 : 10, 40, 90, 160 px pour 1, 2, 3, 4 unités, soit environ
  700 à 6 300 px/s à 70 rapports/s ; `0` rend le défilement linéaire. Ajoutée
  après l'essai sur le clavier : linéaire, le défilement manquait d'accélération ;
- sens : réglage « défilement naturel » de macOS, relu au début de chaque geste.

Le regroupement par 80 ms du projet d'origine (copie du pilote Windows) est
supprimé : il produisait au plus 12,5 événements par seconde, contraire à
l'exigence de fluidité.

## 4. Bouton central : clic ou défilement

Machine à états, par clavier, sans temporisation :

| Événement | Effet |
|---|---|
| Appui (première source) | Début du geste, parcours = 0, sens de défilement relu |
| Rapport `0x16` | Parcours += \|h\| + \|v\| ; défilement seulement au-delà du seuil |
| Relâché (dernière source) | Clic central si parcours < seuil et `click_if_no_scroll` |
| Déconnexion, veille | Geste annulé, aucun clic |
| Rechargement | Geste conservé (annulé seulement si le défilement est désactivé) |

Sources du bouton central :

| Transport | Sources du geste | Rôle du bouton HID 3 |
|---|---|---|
| Bluetooth (un seul périphérique) | bouton 3 (rapport `0x02`) et rapport vendeur `0x15` | source du geste ; chaque rapport `0x02` réaffirme le bouton 3. Le geste démarre en pratique par `0x15` : si le relâché de cette source se perd, un rapport `0x02` portant un **mouvement** avec le bouton relâché le prouve (aucun mouvement n'est émis bouton tenu, H4) et termine le geste, sans clic (`mtp_gesture_motion_proves_release`) |
| USB (récepteur à 3 interfaces) | usage vendeur `FFA0:FB` uniquement, comme le projet d'origine | sert seulement à la décision du tap : il peut se trouver sur une autre interface et provoquerait sinon un double clic |

**Unité du seuil** : unités de défilement du firmware (valeurs 1 à 7 portées
par chaque rapport `0x16`), cumulées depuis l'appui. C'est une mesure de
déplacement et non un nombre d'événements : un mouvement rapide (gros rapports)
ou lent (beaucoup de petits rapports) franchit le même seuil. Le firmware applique
en plus sa propre zone morte, non documentée. Valeur initiale : 3, à valider.

Une fois le seuil franchi, le rapport qui le franchit est rendu en entier ; les
rapports précédents (sous le seuil) sont ignorés. Le parcours additionne les
valeurs absolues : un aller-retour compte double. Un rapport peut porter jusqu'à
7 unités, donc la tolérance aux petits mouvements repose aussi sur la zone morte
du firmware ; le journal `debug` (`travel=`) sert à régler le seuil.

**Conséquences du clic différé** : le clic central est émis au relâchement
(appui + relâché synthétiques consécutifs). Ce qui ne marche plus avec le bouton
central du TrackPoint :

- le maintien prolongé du bouton central (« appui long ») ;
- le glisser avec bouton central (panoramique 3D, défilement automatique), car le
  firmware transforme de toute façon le mouvement en défilement.

Une souris externe n'est pas concernée. Pour retrouver le comportement natif du
TrackPoint, mettre `scroll.enabled = false`.

## 5. Neutraliser les événements natifs sans API privée

Quartz n'indique pas quel périphérique a émis un événement. L'attribution repose
sur l'état lu **directement dans les rapports HID du clavier**, qui arrivent au
daemon avant que WindowServer ne produise l'événement correspondant.

| Événement Quartz | Règle |
|---|---|
| Appui central (bouton 2) non synthétique | Retenu seulement si le bouton central du TrackPoint est tenu à cet instant |
| Glisser / relâché central (bouton 2) | Retenus seulement pendant qu'un tel appui est retenu |
| Autres boutons (1, 3, 4…) | Jamais touchés |
| Molette non continue | Retenue pendant que le bouton central du TrackPoint est tenu, et une fois par rapport `0x02` du clavier portant une valeur de molette (« dû »), ce qui couvre le dernier événement natif arrivé après le relâché. Ce qui reste dû est effacé 250 ms après la fin du geste (`MTP_OWED_GRACE_MS`, délai unique armé par le relâché) |
| Défilement continu (trackpad) | Jamais touché |
| Événements synthétiques du daemon | Jamais touchés (marqués et injectés en aval) |

Garanties : la paire appui/relâché est décidée à chaque appui ; aucun bouton ne
peut rester enfoncé dans les applications. Si le daemon s'arrête pendant un
geste, le relâché natif passe (relâché orphelin, sans effet). Si le système
désactive le tap pour dépassement de délai, l'état d'appariement est remis à
zéro.

Limites connues :

- un clic central ou une molette d'une souris externe utilisés **pendant** que
  le bouton central du TrackPoint est tenu sont retenus ; un relâché central de
  souris externe entrelacé avec un geste TrackPoint peut l'être aussi ;
- un « dû » resté en suspens (événement natif arrivé avant son rapport, ou
  macOS n'émettant pas un événement par rapport) ne survit pas plus de 250 ms
  au relâché ; avant le correctif de l'audit du 2026-11-22, il pouvait retenir
  un cran de molette d'une souris externe jusqu'au geste suivant ;
- un seul clavier à la fois : l'état de filtrage est commun à tous les
  périphériques ; un geste sur l'un retient la molette et le clic central des
  autres.

Le projet d'origine utilisait trois fonctions privées (`CGEventCopyIOHIDEvent`,
`IOHIDEventGetSenderID`, `IOHIDEventGetFloatValue`) pour identifier la molette
Bluetooth. Elles sont supprimées : uniquement des API publiques.

**Deux event taps** au lieu d'un :

- boutons (appui, relâché, glisser « autre bouton ») : armé tant qu'un clavier
  est connecté ; événements rares ;
- molette : armé **uniquement pendant un geste** (et tant qu'un événement natif
  est dû, 250 ms au plus après le relâché). Le défilement du trackpad et de la
  souris ne transite donc pas par le daemon en temps normal.

Armer et désarmer passent par `set_tap()`, qui n'appelle `CGEventTapEnable` que
si l'état change. Constaté sur macOS 27 : désactiver un tap envoie
`kCGEventTapDisabledByUserInput` à son propre callback. Une version de
développement antérieure à la 1.0.0 y réagissait en réarmant (`update_taps()`),
ce qui redésactivait le tap de molette : boucle de plusieurs dizaines de
milliers d'appels par seconde, avec autant de lignes de journal. Ce signal est désormais ignoré (c'est le daemon
lui-même qui a désactivé le tap) ; seul `kCGEventTapDisabledByTimeout` remet
l'appariement à zéro et réarme. Mesuré après correction : 0 ligne de journal et
0,0 à 0,1 % de CPU au repos sur 20 s, clavier connecté.

## 6. Permissions : les deux sont indispensables

| Permission | Pourquoi | Preuve |
|---|---|---|
| Surveillance de l'entrée | Lire les rapports du clavier | Sans elle, `IOHIDManagerOpen` et `IOHIDDeviceOpen` renvoient `kIOReturnNotPermitted` (`0xE00002E2`) sur ce clavier : mesuré le 2026-11-21. En Bluetooth le clavier est un seul périphérique dont l'usage principal est « clavier » (`0001:0006`) : impossible de n'ouvrir que la partie pointeur. |
| Accessibilité | Injecter défilement et clic (`CGEventPost`), retenir les événements natifs (event tap modifiant) | `CGPreflightPostEventAccess()` est faux sans elle ; un event tap actif ne peut être créé sans elle. |

Si `scroll.enabled = false`, l'Accessibilité n'est plus demandée : seule la
sensibilité est gérée, et **aucun rappel d'entrée n'est enregistré** : aucun
rapport du clavier n'atteint alors le processus.

Quand le défilement est actif, le rappel de rapports d'IOKit reçoit aussi les
rapports clavier (`0x01`), car ils partagent le périphérique Bluetooth. Le daemon
les écarte à la première comparaison, sans les copier, les stocker ni les
journaliser.

**État du firmware** : le mode *Preferred Scrolling* (`0x09 = 1`) n'est activé
que si le daemon peut aussi neutraliser ses effets natifs (taps créés, donc
Accessibilité accordée). Sinon, et à l'arrêt du daemon (`SIGTERM` : `stop`,
fermeture de session, désinstallation), le clavier est remis en mode natif
(`0x09 = 0`) : il se comporte comme un clavier ordinaire, sans clic parasite.
Après un plantage, ce retour n'a pas lieu ; launchd relance le daemon en 30 s au
plus.

## 7. Configuration : property list plutôt que TOML

`~/.config/magictrackpoint/config.plist`, mêmes sections et clés que le TOML
proposé.

- Foundation lit nativement les plist : aucune dépendance, aucun analyseur à
  écrire ni à sécuriser.
- `plutil -lint` valide le fichier ; `plutil -replace scroll.speed -float 1.5
  ~/.config/magictrackpoint/config.plist` le modifie en une commande.
- TOML aurait exigé une bibliothèque tierce ou un analyseur maison : plus de code
  exposé, sans bénéfice fonctionnel.

Fichier absent : valeurs par défaut. Clé invalide : valeur par défaut pour cette
clé et erreur journalisée. Clé inconnue : signalée. Taille maximale : 64 Kio.

Exception, **échec fermé** : si le choix de défilement ne peut pas être lu
(`scroll.enabled` invalide, section `scroll` qui n'est pas un dictionnaire,
fichier présent mais illisible ou mal formé), le défilement reste **désactivé**
(`mtp_failed_config`). C'est le seul réglage qui fait arriver des rapports du
clavier au processus : une faute de frappe ne doit pas le réactiver.

## 8. Signature et autorisations TCC

macOS rattache une autorisation à l'**exigence désignée** (*designated
requirement*) de la signature. Avec une signature ad hoc, cette exigence est
l'empreinte exacte du binaire : chaque recompilation produit un « nouveau »
programme et il faut réaccorder les deux autorisations. On ne suppose donc pas
qu'une signature ad hoc conserve les autorisations.

Stratégie retenue, sans aucune génération de certificat :

1. Utiliser une identité **déjà présente** dans le trousseau. Ce Mac possède un
   certificat *Developer ID Application* : son exigence désignée repose sur
   l'identifiant (`com.jcbaptiste.magictrackpoint`) et l'équipe, donc les
   autorisations survivent aux recompilations et mises à jour.
2. À défaut : *Apple Development*, puis ad hoc avec avertissement explicite.
3. Surcharge possible : `MTP_SIGN_IDENTITY`.

Le binaire est autonome mais porte un `Info.plist` intégré (section
`__TEXT,__info_plist`), qui lui donne un identifiant stable. Signature avec
*hardened runtime*, sans entitlement.

## 9. Lancement et cycle de vie

LaunchAgent `~/Library/LaunchAgents/com.jcbaptiste.magictrackpoint.plist` :

| Clé | Valeur | Raison |
|---|---|---|
| `RunAtLoad` | vrai | démarrage à l'ouverture de session |
| `KeepAlive` | `SuccessfulExit = false` | redémarrage seulement après un arrêt anormal |
| `ThrottleInterval` | 30 s | amortit une boucle de plantage |
| `ProcessType` | `Interactive` | latence d'entrée minimale |
| `LimitLoadToSessionType` | `Aqua` | session graphique uniquement |

Aucun processus root. `SIGTERM` (fermeture de session, `launchctl bootout`) :
arrêt propre, code 0, pas de redémarrage.

Permission manquante, ou échec d'ouverture HID ou de création des taps : le
daemon ne quitte pas (ce qui provoquerait des redémarrages en boucle). Il revérifie
toutes les 5 s, **seulement tant que quelque chose manque** : macOS n'envoie
aucune notification à l'octroi. Une fois tout en place, plus aucune minuterie.
Constaté sur macOS 27 : cette revérification voit l'Accessibilité accordée,
mais pas la Surveillance de l'entrée, que `IOHIDCheckAccess` continue de
renvoyer refusée jusqu'au redémarrage du processus. D'où
`magictrackpointctl permissions`, qui redémarre le daemon. C'est la seule
minuterie périodique du daemon ; elle tourne indéfiniment si une permission
n'est jamais accordée (choix conservé par le client après l'audit du
2026-11-22).

**Retrait de l'Accessibilité en cours de route** : macOS ne le notifie pas. Le
daemon la revérifie à chaque appui du bouton central (un événement, pas une
minuterie), au réveil et au rechargement. Si elle a disparu : taps détruits,
rappels d'entrée retirés, firmware remis en mode natif (le clic central natif
fonctionne à nouveau), statut `accessibility=MISSING`, et la revérification de
5 s reprend jusqu'au nouvel octroi.

Une écriture de configuration en échec (lien Bluetooth pas encore prêt au
réveil, par exemple) est retentée 3 fois au plus, **jamais depuis un rappel
d'entrée ni pendant un geste** : si le défilement est actif, au rapport suivant
du clavier (preuve que le lien est prêt), différé après le rappel ; sinon aucun
rapport n'arrive, donc après 2, 4 puis 8 s. Pendant une écriture (synchrone),
les deux taps sont suspendus : ni les boutons ni la molette des autres souris
n'attendent.

## 10. Administration

Pas de service IPC. `magictrackpointctl` est un script shell :
`launchctl` pour démarrer/arrêter, `SIGHUP` pour recharger, redémarrage pour
redemander les permissions (`magictrackpointctl permissions` : la demande doit
venir du processus autorisé lui-même, pas du script), lecture d'un fichier
d'état (`~/Library/Caches/com.jcbaptiste.magictrackpoint/status`) que le daemon
réécrit à chaque changement d'état (permissions, connexion, rechargement). Il ne
contient aucune donnée d'entrée.

Journal : `os_log`, sous-système `com.jcbaptiste.magictrackpoint`. Niveau `error`
par défaut ; `debug` ajoute le résumé de chaque geste (parcours, clic ou non) et
les octets de défilement du rapport `0x16` — jamais de touche.

## 11. Hypothèses à confirmer sur le matériel

Ces points ne peuvent pas être prouvés sans manipuler le clavier. Le niveau de
journal `debug` a été conçu pour les trancher.

| # | Hypothèse | Indice disponible | Si elle est fausse |
|---|---|---|---|
| H1 | Le rappel HID du daemon arrive avant l'événement Quartz correspondant | Hypothèse du projet d'origine, qui fonctionne sur ce Mac | Clic central natif occasionnel en plus |
| H2 | En Bluetooth, le rapport `0x16` porte les deux axes | Code d'origine (il ignore le vertical de `0x16` pour ne pas compter deux fois) | Pas de vertical : utiliser la molette du rapport `0x02` |
| H3 | L'état du bouton central est visible (bouton 3 et/ou rapport `0x15`) | Code d'origine | Aucun défilement (journal : `ignored`) |
| H4 | Le curseur ne bouge pas pendant un geste | À mesurer : `pointer-motion-reports` dans le journal | Ajouter un filtrage du mouvement |
| H5 | Le rythme des rapports `0x16` donne un défilement fluide | — | Ajuster `speed`, éventuellement lisser |
| H6 | Sens de défilement conforme (réutilisé du code d'origine) | — | Inverser le signe |
| H7 | Seuil 3 adapté | — | Ajuster la valeur par défaut |
| H8 | Table octet → unités : `FE` vaut −1 comme `FF`, `F9` vaut −6 (observé sur le pilote Windows) | Reprise telle quelle | Haut/gauche une unité plus lent : passer au complément à deux |

### Résultats sur le clavier Bluetooth (MacBook Pro M4, macOS 27, 2026-11-22)

55 gestes journalisés au niveau `debug`, 0 erreur,, plus les observations de l'utilisateur.

| # | Résultat | Preuve |
|---|---|---|
| H1 | **Confirmée** | Clics centraux sur un lien dans Safari : un onglet par clic, jamais deux (observation) |
| H2 | **Confirmée** | Rapports `0x16` avec `v≠0` (2 793) et `h≠0` (374), jamais les deux à la fois ; aucun rapport hors geste (`held=no` : 0) |
| H3 | **Confirmée** | 55 débuts et fins de geste ; source `vendor` (rapport `0x15`) en Bluetooth |
| H4 | **Confirmée** | `pointer-motion-reports=0` sur les 55 gestes, appui fort compris ; curseur immobile (observation) |
| H5 | **Confirmée** | Un rapport toutes les 14 ms (médiane ; 90 % sous 29 ms), soit environ 70 par seconde |
| H6 | **Confirmée** | Sens identique au trackpad dans Safari (observation) |
| H7 | **Confirmée** | Clics : parcours 0 sur les 27 ; défilements : parcours 10 au minimum. Le seuil 3 laisse de la marge des deux côtés |
| H8 | **Infirmée, corrigée** | Haut/gauche plus lents (observation). Une poussée progressive donne `01→02→03` dans un sens et `FF→FE→FD` dans l'autre : `FE` et `FD` sont les miroirs de `02` et `03`. Lecture en octet signé, plage ±7 ; même vitesse dans les deux sens après correction (observation) |

Le descripteur HID du clavier ne tranche pas H8 : le rapport `0x16` y est
déclaré comme deux octets non signés (0–255) d'une page vendeur.

## 12. Audit du 2026-11-22 et version 1.0.1

Trois audits indépendants (Codex, Claude, Grok) de la version 1.0.0, puis
revérification de chaque constat : [audits/2026-11-22-synthese.md](audits/2026-11-22-synthese.md).
Corrigé en 1.0.1 :

| Constat | Correction |
|---|---|
| Molette « due » résiduelle | effacée 250 ms après le relâché (§5) |
| Relâché `0x15` perdu | fin du geste prouvée par un mouvement bouton relâché (§4) |
| Retrait de l'Accessibilité non vu | revérifiée à chaque appui, au réveil, au rechargement (§9) |
| Écritures retentées dans un rappel d'entrée | différées, hors geste, minuterie bornée sans défilement ; deux taps suspendus (§9) |
| Config invalide → défilement réactivé | échec fermé (§7) |
| `--prebuilt` sans équipe épinglée | `install.sh` exige l'équipe de la release ; vérifie, exécute et installe une copie privée |

Arbitrages du client, conservés tels quels : la revérification de 5 s tant
qu'une permission manque (§9) et le filtrage de la molette et du clic central
de toute souris pendant un geste TrackPoint (§5). La documentation les décrit
désormais exactement.

## 13. Licence et code propre (1.0.2)

Jusqu'à la 1.0.1, une partie du code venait du projet trackpoint-daemon-macos
(hoyaaaa). À la demande du client, la version 1.0.2 passe sous **GNU GPL
version 3 ou ultérieure** et n'en contient plus aucun code. Les trois passages
encore repris ont été réécrits autrement :

| Avant | Réécrit |
|---|---|
| Vérification qu'une interface déclare le rapport de configuration, par dictionnaire de correspondance | `interface_has_report` : parcours des éléments HID de l'interface (type et numéro de rapport) |
| Lecture des propriétés VID/PID | `hid_int_property` : clé par nom, entier signé 32 bits, −1 si absente |
| Octet de défilement → unités, par plages | `mtp_wheel_units` : conversion en octet signé (complément à deux), bornée à ±7 |

Ce qui reste commun relève des **faits** : identifiants du clavier, formats et
numéros de rapports, commandes de configuration, que le droit d'auteur ne
protège pas. Une comparaison ligne à ligne avec le code d'origine ne trouve
plus que des signatures de fonctions imposées par les API d'Apple. Le test
exhaustif des 256 valeurs d'octet confirme que le comportement est inchangé.

## 14. Touches spéciales (1.1.0)

Mesuré sur le clavier Bluetooth le 2026-11-23 : plusieurs touches de la rangée
du haut envoient le rapport vendeur `0x05` au lieu d'une touche standard, que
macOS ignore (aucun raccourci système ni Karabiner ne peut les voir).

| Touche | Code (13 bits) | Action |
|---|---|---|
| F4 | `0x0BB` | coupe / rétablit le micro par défaut |
| F10 | `0x0B6` | Centre de contrôle, module Bluetooth ; seconde pression : fermeture |
| F8, F9, F11, F12 | `0x0C1`, `0x0BC`, `0x1B7`, `0x0B8` | aucune (relâché : `0`) |
| Impr. écran | touche standard (page 7, usage `0x46`, F13 pour macOS) | envoie ⇧⌘5 |

**Lecture sans la frappe.** Le descripteur déclare le code comme 13 éléments
d'un bit (page `0xFF00`, usages `0xF1`–`0xFD`) : IOKit le livre bit par bit.
Le daemon ne s'abonne qu'à cette page et à l'usage Impr. écran, par le rappel
de **valeurs** filtré par correspondance ; il reconstruit le code une fois tous
les bits d'un rapport reçus (`mtp_key_bit`, `mtp_key_settle`, testés avec les
séquences mesurées). Ce rappel ne voit jamais les touches de frappe, même
défilement désactivé ; les rapports complets restent réservés au défilement.

**Micro (F4).** Propriété *mute* du périphérique d'entrée par défaut, via Core
Audio : aucun processus lancé, aucun son lu. macOS n'affiche rien : un son
système (*Pop* coupé, *Tink* rétabli) et la ligne `microphone=` du statut
donnent l'état.

**Bluetooth (F10).** Aucune API publique n'ouvre le Centre de contrôle. L'API
d'accessibilité (déjà accordée) le permet : appui sur l'élément de la barre
des menus `com.apple.menuextra.controlcenter` (porté par `MenuBarAgent` sous
macOS 27), puis action « afficher les détails » du module
`controlcenter-bluetooth`. Recherche par identifiants stables, jamais par
libellés localisés ; aucun contenu n'est lu ni journalisé ; délai de 0,25 s par
appel. L'action *AXPress* du module **basculerait le Bluetooth** et
déconnecterait le clavier : elle n'est jamais utilisée. Tout échec retombe sur
*Réglages Système → Bluetooth* (URL `x-apple.systempreferences:`).

Seconde pression : fermeture complète. Mesuré sous macOS 27 : appuyer sur
l'élément de la barre des menus pendant que la liste Bluetooth est affichée ne
ramène qu'au panneau principal, après une animation d'environ 300 ms pendant
laquelle aucun élément n'est visible ; un second appui ferme tout. Le daemon
observe donc toutes les 100 ms, n'appuie de nouveau qu'une fois le panneau
principal réellement affiché, et s'arrête dès qu'il ne reste aucune fenêtre du
Centre de contrôle. Il n'appuie jamais panneau fermé (il ne peut donc pas le
rouvrir) ; borné à 3 appuis et 2 s. Une première version, qui vérifiait au
bout de 200 ms, concluait à tort à la fermeture en pleine animation.

**Capture (Impr. écran).** Événement clavier synthétique ⇧⌘5 (code de touche
`0x17`, indépendant de la disposition), injecté au niveau HID pour que les
raccourcis globaux (CleanShot) le reçoivent ; marqué comme les autres
événements du daemon.

**Permissions.** Surveillance de l'entrée pour les trois touches ;
Accessibilité aussi pour F10 et Impr. écran : elle est donc demandée dès que
l'une de ces touches est active, même défilement désactivé.

**Course au démarrage corrigée.** `magictrackpointctl reload` envoyé juste
après un démarrage arrivait avant que le processus ne gère `SIGHUP`, pendant
son chargement : launchd l'arrêtait (« last terminating signal = Hangup »).
La commande attend désormais le fichier d'état (5 s au plus) ; le daemon
ignore aussi `SIGHUP` dès l'entrée de `main`.
