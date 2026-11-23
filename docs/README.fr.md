# MagicTrackpoint

Petit daemon macOS, sans interface, pour le clavier **Lenovo ThinkPad TrackPoint
Keyboard II**. Il :

- règle la **sensibilité matérielle** du TrackPoint (1 à 9) et la réapplique
  après reconnexion et sortie de veille ;
- transforme **bouton central tenu + TrackPoint** en défilement vertical et
  horizontal, avec vitesse et seuil réglables ;
- émet un **clic central** seulement quand le bouton a été relâché sans défiler ;
- donne une action aux touches **F4** (couper le micro), **F10** (Bluetooth du
  Centre de contrôle) et **Impr. écran** (⇧⌘5).

Un seul processus (`magictrackpointd`), lancé par un LaunchAgent utilisateur, sans
root, sans réseau, sans dépendance hors macOS. Logiciel libre sous licence
**GNU GPL version 3 ou ultérieure** ([LICENSE](../LICENSE)), © 2026
Jean-Christophe Baptiste. Merci à hoyaaaa, dont
[trackpoint-daemon-macos](https://github.com/hoyaaaa/trackpoint-daemon-macos) a
documenté le protocole HID du clavier ; MagicTrackpoint n'en contient aucun code.

## Matériel

| Clavier | VID:PID | État |
|---|---|---|
| TrackPoint Keyboard II, Bluetooth | `17EF:60E1` | Cible principale |
| TrackPoint Keyboard II, récepteur USB | `17EF:60EE` | Même protocole, non vérifié ici |

Aucun autre périphérique n'est ouvert ni reconfiguré (une souris externe est
toutefois filtrée pendant un geste TrackPoint : voir les limites). macOS 12 ou
plus récent ;
binaire universel (Apple Silicon et Intel).

## Installation

Prérequis : outils en ligne de commande Xcode (`xcode-select --install`).

```bash
bash scripts/install.sh
```

Le script compile, lance les tests, signe, installe et démarre :

| Élément | Emplacement |
|---|---|
| Daemon | `~/.local/bin/magictrackpointd` |
| Outil d'administration | `~/.local/bin/magictrackpointctl` |
| LaunchAgent | `~/Library/LaunchAgents/com.jcbaptiste.magictrackpoint.plist` |
| Configuration | `~/.config/magictrackpoint/config.plist` (créée si absente, jamais écrasée) |

`bash scripts/install.sh --check` compile, teste et signe sans rien installer.

Si l'ancienne application TrackPointD tourne encore, quittez-la et retirez-la des
éléments d'ouverture : deux daemons sur le même clavier se gênent.

### Signature

Le script n'importe ni ne génère aucun certificat. Il utilise, dans l'ordre :

1. la variable `MTP_SIGN_IDENTITY` (nom ou empreinte SHA-1, ou `-` pour ad hoc) ;
2. un certificat **Developer ID Application** du trousseau ;
3. un certificat **Apple Development** ;
4. sinon une signature **ad hoc**.

Avec 2 ou 3, les autorisations macOS survivent aux recompilations : elles sont
liées à l'identifiant `com.jcbaptiste.magictrackpoint` et au certificat.
Avec une signature ad hoc, elles sont liées à l'empreinte exacte du binaire :
**il faut les accorder de nouveau après chaque réinstallation**, en supprimant
d'abord l'ancienne entrée.

## Permissions

Deux autorisations, toutes deux indispensables (démonstration dans
[docs/architecture.md](architecture.md#6-permissions--les-deux-sont-indispensables)) :

| Réglages Système → Confidentialité et sécurité | Pourquoi |
|---|---|
| **Surveillance de l'entrée** | lire les rapports du clavier (bouton central, défilement) et lui envoyer la sensibilité |
| **Accessibilité** | produire le défilement et le clic, neutraliser le bouton central natif |

Au premier lancement, le daemon les demande à macOS, ce qui ajoute normalement
`magictrackpointd` aux deux listes : il suffit de l'activer. Sinon, bouton **+**,
`Cmd+Maj+G`, puis le chemin `~/.local/bin/magictrackpointd`.

Le plus simple est de répéter cette commande jusqu'à ce qu'elle réponde
`All permissions granted.` :

```bash
magictrackpointctl permissions
```

Elle redémarre le daemon, qui redemande alors les autorisations (c'est lui qui
doit les obtenir, pas le terminal), puis ouvre Réglages Système sur la première
qui manque et rappelle le chemin à ajouter. Le redémarrage est nécessaire :
constaté sur macOS 27, un processus en cours d'exécution continue de voir la
Surveillance de l'entrée comme refusée après son activation, alors que
l'Accessibilité est prise en compte en moins de 5 secondes. macOS n'affiche sa
propre fenêtre de demande que la première fois ; ensuite, il faut activer
l'interrupteur dans Réglages.

Avec `scroll.enabled = false`, seule la Surveillance de l'entrée est nécessaire.

## Configuration

Fichier : `~/.config/magictrackpoint/config.plist` (modèle commenté :
[config/config.example.plist](../config/config.example.plist)). Toutes les clés sont
facultatives.

| Clé | Type | Défaut | Rôle |
|---|---|---|---|
| `trackpoint.sensitivity` | entier 1–9 | 7 | sensibilité matérielle du pointeur |
| `scroll.enabled` | booléen | vrai | bouton central + TrackPoint = défilement |
| `scroll.speed` | réel 0,1–10 | 1,0 | multiplicateur ; 1 unité du clavier = 10 px × speed |
| `scroll.acceleration` | réel 0–2 | 1,0 | plus on appuie fort, plus ça défile vite ; `0` = linéaire |
| `scroll.horizontal` | booléen | vrai | défilement horizontal |
| `scroll.threshold` | entier 0–50 | 3 | seuil clic/défilement, en unités de défilement du clavier |
| `middle_button.click_if_no_scroll` | booléen | vrai | clic central si aucun défilement |
| `keys.microphone` | booléen | vrai | F4 coupe ou rétablit le micro par défaut (son *Pop* = coupé, *Tink* = rétabli) |
| `keys.bluetooth` | booléen | vrai | F10 ouvre le Centre de contrôle sur le Bluetooth ; une seconde pression le ferme |
| `keys.screenshot` | booléen | vrai | Impr. écran envoie ⇧⌘5 (capture macOS, CleanShot…) |
| `logging.level` | `error`, `info`, `debug` | `error` | verbosité du journal |

Modifier puis appliquer :

```bash
plutil -replace scroll.speed -float 1.5 ~/.config/magictrackpoint/config.plist
```

```bash
magictrackpointctl check
```

```bash
magictrackpointctl reload
```

Une valeur invalide est signalée et remplacée par sa valeur par défaut ; le
reste du fichier s'applique. Fichier absent : toutes les valeurs par défaut.

### Le seuil, concrètement

Pendant que le bouton central est tenu, le clavier lui-même transforme le
mouvement du TrackPoint en petits pas de défilement (1 à 7 unités par rapport).
Le daemon additionne ces unités depuis l'appui :

- total < seuil au relâchement → **clic central**, aucun défilement ;
- total ≥ seuil → **défilement**, et aucun clic au relâchement.

Un seuil plus haut tolère davantage de mouvement involontaire pendant un clic ;
un seuil plus bas fait démarrer le défilement plus tôt. `0` : le moindre pas
défile.

### L'accélération, concrètement

Le clavier mesure lui-même la force de l'appui : chaque rapport vaut 1 unité
pour un appui léger, 3 à 4 pour un appui fort. Chaque rapport défile
`unités^(1 + acceleration) × 10 px × speed` :

| Appui | `acceleration = 0` | `1` (défaut) | `2` |
|---|---|---|---|
| léger (1) | 10 px | 10 px | 10 px |
| moyen (2) | 20 px | 40 px | 80 px |
| fort (3) | 30 px | 90 px | 270 px |

L'appui léger reste précis quel que soit le réglage ; seuls les appuis plus
forts accélèrent. Le clavier envoie environ 70 rapports par seconde.

### Ce que change le clic différé

Le clic central n'est envoyé qu'au relâchement, quand on sait qu'il n'y a pas eu
de défilement. Avec le bouton central **du TrackPoint**, on ne peut donc plus
faire d'appui long ni de glisser-bouton-central (panoramique d'un logiciel 3D,
défilement automatique). Une souris externe n'est pas concernée. Pour retrouver
le comportement natif : `scroll.enabled = false`.

## Administration

| Commande | Effet |
|---|---|
| `magictrackpointctl status` | état launchd, permissions, claviers connectés, réglages appliqués, configuration |
| `magictrackpointctl reload` | relit la configuration et la réapplique (signal `SIGHUP`) |
| `magictrackpointctl permissions` | redémarre le daemon pour qu'il redemande les autorisations, ouvre Réglages Système sur la première qui manque ; code de sortie 3 tant qu'il en manque une |
| `magictrackpointctl stop` | arrête le daemon jusqu'à la prochaine session ou `start` |
| `magictrackpointctl start` / `restart` | démarre / redémarre |
| `magictrackpointctl log` | affiche le journal en direct |
| `magictrackpointctl check [FICHIER]` | valide une configuration |

## Diagnostic

| Symptôme | Vérification |
|---|---|
| Rien ne se passe | `magictrackpointctl status` : `input_monitoring`, `accessibility` à `granted`, `hid=open`, `event_taps=ready`, et au moins une ligne `device.` |
| `scroll=configured, inactive` | l'Accessibilité manque : le clavier reste en mode natif tant qu'elle n'est pas accordée |
| `MISSING` | `magictrackpointctl permissions` |
| `MISSING` alors que l'autorisation est cochée | signature ad hoc après réinstallation : supprimer l'entrée (bouton **−**) puis `magictrackpointctl permissions` |
| `sensitivity:FAILED` | le clavier a refusé la commande ; déconnecter puis reconnecter le clavier |
| Défilement trop lent / trop rapide | `scroll.speed` |
| Clic central qui défile, ou défilement qui clique | `scroll.threshold` |
| Comportement inattendu | passer `logging.level` à `debug`, `magictrackpointctl reload`, puis `magictrackpointctl log` : chaque geste est résumé (parcours, défilement, clic). Le journal ne contient jamais de touche. |
| Karabiner-Elements | désactiver *Modify events* pour ce clavier : Karabiner en prend le contrôle exclusif |

Pour voir l'utilisation des ressources :

```bash
ps -o pid,%cpu,rss,command -p "$(pgrep -x magictrackpointd)"
```

## Désinstallation

```bash
bash scripts/uninstall.sh
```

Supprime le LaunchAgent, les deux binaires et le fichier d'état. La
configuration est conservée ; `--purge` la supprime aussi. Le script affiche les
commandes `tccutil` pour retirer les deux autorisations, sans les exécuter.

## Développement

```bash
make
```

```bash
make test
```

Code : `src/mtp_core.h` (logique pure, testée) et `src/magictrackpointd.m`
(effets système). Décisions et hypothèses : [docs/architecture.md](architecture.md).
Tests manuels avec le clavier : [docs/tests-manuels.md](tests-manuels.md).

## Sécurité et confidentialité

- Aucun accès réseau, aucune mise à jour automatique, aucune télémétrie.
- Jamais de root ; LaunchAgent de la session utilisateur.
- Les rapports clavier partagent le périphérique Bluetooth et passent donc par le
  daemon : ils sont écartés à la première comparaison, jamais copiés, stockés ni
  journalisés.
- Les trois touches spéciales (F4, F10, Impr. écran) parviennent au daemon
  seules, sans la frappe. F10 n'utilise jamais l'interrupteur Bluetooth (qui
  déconnecterait le clavier) ; F4 ne lit aucun son, il ne change que le
  réglage « muet » du micro.
- Seuls le bouton central et la molette sont filtrés, et seulement pendant un
  geste TrackPoint (plus 250 ms au plus après) ; le trackpad (défilement
  continu) n'est jamais touché.
- Échec fermé : si la configuration ne peut pas être lue, le défilement (seule
  fonction qui reçoit des rapports du clavier) reste désactivé.
- L'installation depuis l'image disque n'accepte que le binaire signé par
  l'équipe Developer ID de la release.
- Uniquement des API publiques d'Apple.
- Signaler une faille : en privé, comme décrit dans [SECURITY.md](../SECURITY.md)
  (onglet *Security* du dépôt, *Report a vulnerability*), jamais dans une issue
  publique.

## Limites connues

- Le récepteur USB n'a pas été testé sur ce Mac.
- Pendant que le bouton central du TrackPoint est tenu, le bouton central et la
  molette d'une souris externe utilisés **au même moment** sont ignorés.
- Un seul clavier TrackPoint à la fois : avec deux, un geste sur l'un retient
  aussi la molette et le clic central de l'autre.
- La révocation de la Surveillance de l'entrée pendant que le daemon tourne
  n'est pas détectée : relancer avec `magictrackpointctl restart`. Celle de
  l'Accessibilité l'est au prochain appui du bouton central (clavier remis en
  mode natif).
- Tant qu'une autorisation manque, le daemon revérifie toutes les 5 s ; plus
  aucune minuterie ensuite.
- À l'arrêt, le daemon remet le clavier en mode natif (bouton central et molette
  ordinaires). Après un plantage, launchd le relance en 30 s au plus ; dans
  l'intervalle, un clic central peut suivre un défilement.
- Hypothèses sur le firmware H1 à H8 : confirmées ou corrigées sur le clavier
  Bluetooth le 2026-11-22 ([docs/architecture.md §11](architecture.md#11-hypothèses-à-confirmer-sur-le-matériel)).
  Pas encore vérifiés : niveaux de sensibilité 1 et 9, reconnexion, sortie de
  veille, mémoire sur la durée ([tests manuels](tests-manuels.md)).
- Audits de code : [docs/audits/](audits/).
