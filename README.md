# Logonoff

Temps de présence au poste et temps passé par projet (numéro d'imputation),
calculés à partir des ouvertures, fermetures, verrouillages et
déverrouillages de session Windows. C'est la réécriture en Amalgame de
l'ancienne version C# (service + notifier WinForms + CSV hebdomadaires).

- **Un service Windows** (`logonoff.exe --service`, compte SYSTEM) capte les
  événements de session et d'alimentation, tient la base SQLite et sert
  l'interface web.
- **Une interface web locale**, installable comme application (PWA), sur
  `http://127.0.0.1:8765`, accessible uniquement depuis le poste.
- **Multi-utilisateur** sur un même PC : chaque compte Windows ne voit que
  ses données. Il n'y a pas de connexion à faire : le service identifie
  l'utilisateur d'après le processus du navigateur qui l'appelle.

## Ce qui change par rapport à la version C#

| Avant | Maintenant |
|---|---|
| Une journée = 4 points (arrivée, pause après 11 h 45, reprise après 12 h 30, départ) ; tout autre verrouillage était ignoré | Chaque verrouillage ou déverrouillage ouvre ou ferme une plage ; le temps compté est la somme de ces plages |
| Veille (capot fermé) non gérée : le temps continuait de courir | Veille et reprise ferment et rouvrent les plages |
| Plantage ou coupure de courant : la session restait « ouverte » | Un battement enregistre la dernière présence ; au redémarrage, les plages restées ouvertes sont fermées à ce moment-là |
| Service démarré après l'ouverture de session : la journée commençait sans arrivée | Au démarrage, le service relit l'état réel des sessions |
| Utilisateur deviné (`defaultuser`), un seul compte | Utilisateur identifié par son SID, plusieurs comptes (y compris en RDP) |
| Numéro de semaine `FirstFullWeek` avec un correctif `> 52` | Jours et semaines ISO calculés dans le fuseau local, changement d'heure compris |
| Lieu = IP de la passerelle (`192.168.1.1` est la même chez tout le monde) ; plantage hors réseau | Lieu = adresse MAC de la passerelle, nommable dans l'interface |
| Horaires en dur (8 h 15, vendredi 4 h) | Objectifs par jour, pause déjeuner et notifications réglables par utilisateur |
| Pas de projets | Changement de projet en un clic, répartition automatique du temps, rapport et export CSV |
| Pas de correction possible | Plages et changements de projet modifiables ; journal brut des événements conservé |

## Calculs

- **Plages de présence.** Une plage s'ouvre sur Logon, Unlock ou une
  connexion console/RDP (si la session est active et déverrouillée). Elle se
  ferme sur Lock, Logoff, une déconnexion, Suspend ou Shutdown. Toutes les
  60 s (« battement »), le service compare l'état réel des sessions avec les
  plages ouvertes et corrige l'écart. Un événement manqué coûte donc au plus
  une minute.
- **Journée.** Union des plages coupée à minuit local. Si des plages se
  chevauchent (après une correction), le temps commun n'est compté qu'une
  fois.
- **Pause déjeuner** (optionnelle). Si plus de *N* heures ont été
  travaillées et que la plus longue pause commencée entre 11 h et 15 h est
  plus courte que le minimum, la différence est déduite.
- **Projets.** « Je travaille sur X » enregistre un changement horodaté. Le
  temps de présence est réparti entre les projets selon ces changements. On
  peut ajouter un changement après coup, en indiquant une heure passée.
- **Absences.** Tout trou d'au moins 15 min entre deux plages
  (réglable) est « à qualifier ». Au retour, une notification le propose,
  et un clic ouvre la journée. On découpe l'absence en segments
  consécutifs :
  - *réunion*, *déplacement* ou *autre travail* : compte comme travaillé,
    éventuellement sur un projet précis, qui prime alors sur le projet en
    cours ;
  - *repas* ou *absence personnelle* : non travaillé. Un repas déclaré
    remplace la détection automatique de la pause déjeuner.

  Exemple : réunion IMP-114 de 11:30 à 12:30, puis repas jusqu'à 13:45.
- **Corriger les imputations.** Dans la vue Journée, on peut :
  - changer l'activité et le projet d'une plage, la **découper** à une
    heure donnée, l'ajouter ou la supprimer ;
  - remplacer la répartition calculée par une **répartition saisie**
    (ajout et suppression de lignes, découpe d'une ligne en deux, durées en
    `7:30` ou `7,5`). Elle prime dans le rapport et l'export. « Revenir au
    calcul automatique » l'efface.
- **Rassembler des plages.** Dans Journée, cochez plusieurs plages puis
  « Rassembler ». Il n'en reste qu'une, du début de la première à la fin
  de la dernière : les trous (passage sur le poste d'un collègue,
  intervention…) deviennent du temps travaillé. Les plages doivent être
  sur le même projet, et aucune pause déclarée ne doit se trouver dans
  l'intervalle. Les plages entièrement contenues sont absorbées et les
  notes conservées.
- **Usage personnel.** Trois moyens de ne pas compter du temps passé
  sur l'ordinateur :
  - le bouton **Perso** de l'accueil : le décompte est en pause jusqu'au
    prochain choix de projet, sans notification pendant ce temps ;
  - après coup, une plage, ou une partie de plage avec « Découper »,
    marquée « Personnel (non compté) » ;
  - l'option « hors horaires = personnel » (Paramètres) : la présence au
    poste en dehors des horaires de travail, ou un jour sans objectif,
    n'est pas comptée.

  Une **urgence** se déclare en marquant la plage « Urgence /
  astreinte », avec une **note** de justification (numéro de ticket…).
  Elle est alors comptée, même en dehors des horaires.
- **Heure de fin estimée.** Tant que le repas du jour n'est pas pris
  (pas de repas déclaré, aucune pause de 20 min ou plus dans la plage de
  déjeuner) et que la plage n'est pas passée, l'estimation ajoute la durée
  moyenne des N derniers repas (10 par défaut). Cette durée n'est jamais
  inférieure à la pause minimale réglée.
- **Fin de journée.** Le service prévient (toast Windows ou boîte de
  message) quand l'objectif est atteint, avec un préavis réglable. Deux
  modes : objectif du jour, ou cumul de la semaine à date (comme l'ancien
  notifier).

## Export (Espace Temps)

**Rapport → Export Espace Temps** produit une ligne par jour et par projet,
selon un modèle réglable dans **Paramètres → Export** :

- ligne d'en-tête ;
- modèle de ligne, avec les jetons `{date}` `{date_iso}` `{jour}` `{code}`
  `{libelle}` `{heures}` (7,50) `{heures_point}` `{hhmm}` `{minutes}`
  `{compte}` `{nom}` ;
- encodage UTF-8 ou Windows-1252 ;
- option pour ignorer le temps sans projet.

La pause déduite est retirée d'abord du temps sans projet, pour que le
total exporté égale le temps travaillé.

## Arborescence

```
src/platform.am   chemins, identité du client local, passerelle, toast, navigateur
src/store.am      schéma et requêtes SQLite
src/timecalc.am   jours locaux, totaux, projets, pause, semaine, JSON
src/tracker.am    événements → plages, battement, reprise, notifications
src/web.am        serveur HTTP local, sécurité, API JSON, fichiers statiques
src/main.am       modes --service / --console / --dev / --notify / --open
www/              interface (HTML/CSS/JS sans build) + manifest + service worker
packaging/        icône, ressources Windows, install.cmd / uninstall.cmd
packages/         paquets Amalgame embarqués (build hors ligne)
tools/            vendor-packages.sh, make-icons.py
```

## Compiler sous Windows

### Sans MSYS2 (recommandé)

Avec Amalgame installé par `amalgame-<version>.msi` et l'option « gcc
intégré » (gcc, libgc et OpenSSL fournis), double-cliquer sur
**build.cmd**, ou lancer :

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

nghttp2 n'est pas nécessaire : Logonoff n'utilise pas HTTP/2. Si gcc
n'est pas trouvé automatiquement, définir `GCC_BIN` sur le dossier qui
contient `gcc.exe`.

### Avec MSYS2

Dans un shell **MSYS2 MINGW64** :

```bash
pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-gc mingw-w64-x86_64-openssl
# amc ≥ 0.8.90 dans le PATH (bin/amc.exe de l'archive Windows)
./build.sh
```

`build.sh` précompile les paquets depuis `packages/` (sans réseau), transpile,
lie, puis prépare `dist/` : `logonoff.exe`, `www/`, les scripts
d'installation et les DLL MinGW nécessaires. Un service ne voit pas le
`PATH` de MSYS2, d'où la copie des DLL à côté de l'exécutable.

## Installer

Depuis `dist\`, faire un clic droit sur **install.cmd** puis « Exécuter en
tant qu'administrateur ». Le script :

- copie les fichiers dans `C:\Program Files\Logonoff` ;
- crée le service `Logonoff` (démarrage automatique, redémarrage en cas de
  plantage) et le démarre ;
- ajoute le raccourci *Logonoff* au menu Démarrer.

Les données sont dans `C:\ProgramData\Logonoff\logonoff.db`. Pour
désinstaller, lancer `uninstall.cmd` : les données sont conservées.

Pour transformer l'interface en application : dans Edge ou Chrome, menu →
**Installer Logonoff**.

Pour essayer sans installer le service : `logonoff.exe --console`. La
présence est alors suivie par sondage des sessions, sans les événements
du service, et les données vont dans `%LOCALAPPDATA%\Logonoff`.

## Développer (Linux)

```bash
tools/vendor-packages.sh     # (re)remplit packages/ depuis ~/Développement et ~/.amalgame
./build.sh
LOGONOFF_PORT=18765 ./dist/logonoff --dev
```

En mode `--dev`, l'utilisateur courant est présent du démarrage jusqu'à
l'arrêt. Les données vont dans `dist/data/` (modifiable avec
`LOGONOFF_DATA`), et `LOGONOFF_WWW` permet de servir `www/` directement.

## Paquets Amalgame modifiés pour Logonoff

Ces modifications ne sont pas encore publiées. Elles sont embarquées dans
`packages/` sous un tag local (rev `10ca1000`).

- **amalgame-service v0.3.0** (branche `feature/session-events`) :
  - événements de session et d'alimentation (`EnableSessionEvents`,
    `PollEvents`, `InjectEvent`) ;
  - informations sur les sessions Windows : utilisateur, SID, état,
    verrouillage, appartenance aux administrateurs ;
  - `SendMessage` et `LaunchInSession` ;
  - un job CI Windows.
- **amalgame-datetime v0.3.0** (branche `feature/local-time`) : heure
  locale avec changement d'heure (`LocalOffsetSeconds`, `LocalToEpoch`,
  `Instant.LocalParts/LocalDate/FormatLocal/FromLocal`).
- **amalgame-net-http v0.30.0** (branche `feature/loopback-bind`) :
  `Http1.SetLoopbackOnly(true)` pour écouter uniquement sur 127.0.0.1.

Une fois ces versions taguées sur GitHub, `tools/vendor-packages.sh` pourra
les reprendre du cache comme les autres paquets.
