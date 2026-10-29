# local-coder

Lokale, vom Internet unabhängige KI-Umgebung zum Programmieren. Die Modelle
laufen auf der CPU des eigenen Rechners in rootless Podman-Containern. Als
Oberfläche dient ausschließlich Open WebUI, mit Projekten (Ordnern), eigenen
System-Prompts, angehängtem Wissen und Gedächtnis, ähnlich wie bei
Cloud-Chatdiensten.

Die englische Fassung dieser Beschreibung steht in [README.md](README.md).

## 1. Was es ist

local-coder besteht aus zwei Containern, optional drei:

| Container           | Aufgabe                                                                  |
|---------------------|--------------------------------------------------------------------------|
| `local-coder-webui` | Open WebUI, die Weboberfläche im Browser                                 |
| `local-coder-chat`  | llama-server (llama.cpp) mit dem Chat-Modell                             |
| `local-coder-fim`   | optional: llama-server für die Code-Vervollständigung in VS Code (llama-vscode) |

Aufbau:

```
Browser --> 127.0.0.1:3000 --> [ webui ] --> local-coder-chat:8080
                                                (nur im Container-Netz)
VS Code --> 127.0.0.1:8012 --> [ fim ]          (nur mit AUTOCOMPLETE=1)
```

Der Chat-Container hat keinen Port auf dem Host und keine eigene
Weboberfläche. Er ist nur für Open WebUI erreichbar.

## 2. Was es macht

- Chat mit einem lokalen Sprachmodell (Standard: Qwen3.5-9B), auch ohne
  Netzwerkverbindung.
- **Projekte in Open WebUI:** Ordner mit eigenem System-Prompt und
  angehängtem Wissen. Neue Chats in einem Ordner übernehmen diese
  Einstellungen.
- **Dateien und Wissensbasen:** Texte und Quellcode werden lokal in
  Abschnitte zerlegt und durchsucht. Das dafür nötige Embedding-Modell wird
  bei der Einrichtung aus dem Open-WebUI-Image übernommen.
- **Kein Datenabfluss:** Modelle werden einmalig auf dem Host geladen. Danach
  arbeiten llama-server (`--offline`) und Open WebUI (`OFFLINE_MODE`) ohne
  Internetzugriff. Telemetrie und Update-Prüfungen sind abgeschaltet.
- Die Ports sind standardmäßig nur an `127.0.0.1` gebunden.

## 3. Voraussetzungen

### Hardware

- **Arbeitsspeicher:** mindestens 16 GB. Mit 16 GB ist ein Modell der
  Größenklasse 9B mit 16K Kontext nutzbar, größere Modelle (z.B.
  Qwen3.6-35B-A3B) benötigen 64 GB.
- **CPU:** x86_64 mit AVX2 (empfohlen) oder aarch64, mindestens 4 Kerne.
- **Speicherplatz:**

| Größe      | Verwendung                                           |
|------------|------------------------------------------------------|
| ca. 6 GB   | Chat-Modell (9B), 35B-Modell ca. 24 GB               |
| ca. 2 GB   | Modell für Autovervollständigung (optional)          |
| ca. 8 GB   | Podman-Speicher für die Images                       |
| ab 2 GB    | Daten von Open WebUI (wachsen mit Chats und Uploads) |

### Software

- Linux (ausgelegt auf Linux Mint 22 / Ubuntu 24.04)
- Podman ab 4.0, rootless eingerichtet (Einträge in `/etc/subuid` und
  `/etc/subgid` für den Benutzer)
- Netzwerk-Backend netavark mit aardvark-dns
- podman-compose (empfohlen) oder docker-compose v2 mit aktivem
  Podman-Socket
- curl, coreutils, gawk, sed, grep, iproute2 (`ss`)

Installation unter Debian/Ubuntu/Mint:

```
sudo apt install podman podman-compose aardvark-dns curl iproute2
```

### Netzwerk

Nur für die erste Einrichtung bzw. Aktualisierungen: Zugriff auf
`huggingface.co` (Modelle) und `ghcr.io` (Images).

`setup.sh` prüft alle diese Punkte, bevor etwas verändert wird.

## 4. Dateien

| Datei           | Inhalt                                                   |
|-----------------|----------------------------------------------------------|
| `README.md`     | Beschreibung auf Englisch                                |
| `README_de.md`  | diese Beschreibung (Deutsch)                             |
| `setup.conf`    | Konfiguration mit Standardwerten (Pfade, Ports, Modelle) |
| `setup.sh`      | Prüfung der Voraussetzungen und Einrichtung              |
| `ctl.sh`        | Bedienung im Alltag (start, stop, status, logs)          |
| `cleanup.sh`    | vollständiges Entfernen                                  |
| `common.sh`     | gemeinsame Funktionen der Skripte                        |
| `compose.yaml`  | Definition der Container                                 |
| `Dockerfile`    | Image für llama-server                                   |
| `entrypoint.sh` | Startskript von llama-server im Container                |

Von `setup.sh` erzeugt (nicht von Hand bearbeiten):

| Datei / Verzeichnis | Inhalt                                          |
|---------------------|-------------------------------------------------|
| `.env`              | Werte für compose.yaml, erzeugt aus setup.conf  |
| `.webui_secret`     | Sitzungsschlüssel für Open WebUI                |
| `.local-coder.log`  | Ausgaben von Build und Compose                  |
| `models/`           | Modelle (Standardpfad)                          |
| `data/webui/`       | Daten von Open WebUI (Standardpfad)             |

## 5. Einrichtung

```
cd /DATA/local-coder
vim setup.conf          # optional, Standardwerte passen für 16 GB RAM
./setup.sh --check      # nur prüfen
./setup.sh              # einrichten und starten
```

Danach ist die Oberfläche unter <http://127.0.0.1:3000> erreichbar. Das erste
dort angelegte Konto wird Administrator. Das Konto ist lokal und wird in
`data/webui/webui.db` gespeichert.

`setup.sh` ist wiederholbar. Vorhandene Modelle werden nicht erneut geladen,
abgebrochene Downloads werden fortgesetzt. Die Container werden bei jedem
Aufruf neu angelegt, Daten und Modelle bleiben dabei erhalten.

| Option                  | Wirkung                                        |
|-------------------------|------------------------------------------------|
| `./setup.sh --check`    | nur Voraussetzungen und Konfiguration prüfen   |
| `./setup.sh --no-start` | einrichten, Container nicht starten            |
| `./setup.sh --update`   | zusätzlich neueste Images laden                |

## 6. Konfiguration (setup.conf)

Alle Werte sind in `setup.conf` kommentiert. Nach jeder Änderung:

```
./setup.sh
```

Die wichtigsten Werte:

| Schlüssel                | Bedeutung                                         |
|--------------------------|---------------------------------------------------|
| `MODELS_DIR`             | Ablage der Modelle (Standard: `./models`)         |
| `WEBUI_DATA_DIR`         | Daten von Open WebUI (Standard: `./data/webui`)   |
| `BIND_ADDRESS`           | `127.0.0.1` = nur lokal erreichbar                |
| `WEBUI_PORT`             | Port der Oberfläche (Standard: 3000)              |
| `WEBUI_IMAGE`            | Version von Open WebUI                            |
| `WEBUI_AUTH`             | 1 = Anmeldung, 0 = ohne (nur bei Neuinstallation) |
| `WEBUI_OFFLINE`          | 1 = keine Downloads durch Open WebUI              |
| `WEBUI_TITLE_GENERATION` | automatische Chat-Titel durch das Modell          |
| `WEBUI_BACKGROUND_TASKS` | Tags, Folgefragen, Suchanfragen durch das Modell  |
| `CHAT_MODEL_REPO/_FILE`  | Chat-Modell auf Hugging Face                      |
| `CHAT_ALIAS`             | Modellname in Open WebUI                          |
| `CHAT_CTX`               | Kontextgröße in Tokens                            |
| `CHAT_THREADS`           | CPU-Threads, `auto` = physische Kerne             |
| `CHAT_THINKING`          | Denk-Modus (langsamer, gründlicher)               |
| `AUTOCOMPLETE`           | 1 = Container für die VS-Code-Vervollständigung   |
| `MIN_RAM_GB`             | Mindest-RAM für die Prüfung (Standard: 16)        |

> **Hinweis zu Open WebUI:** Werte wie Titel-Generierung,
> Hintergrund-Aufgaben oder Standardmodell übernimmt Open WebUI nur beim
> ersten Start. Danach gelten die Einstellungen im Admin-Panel. Mit
> `WEBUI_CONFIG_FROM_ENV=1` gelten die Werte aus `setup.conf` bei jedem
> Start, Änderungen im Admin-Panel gehen dann aber beim Neustart verloren.

## 7. Bedienung

| Befehl               | Wirkung                                        |
|----------------------|------------------------------------------------|
| `./ctl.sh start`     | starten, z.B. nach einem Neustart des Rechners |
| `./ctl.sh stop`      | anhalten, der Arbeitsspeicher wird frei        |
| `./ctl.sh restart`   | anhalten und wieder starten                    |
| `./ctl.sh status`    | Zustand, Bereitschaft, RAM- und CPU-Verbrauch  |
| `./ctl.sh logs chat` | Log des Chat-Containers (auch: webui, fim)     |

Nach einem Neustart des Rechners laufen die Container nicht automatisch, der
Start erfolgt mit `./ctl.sh start`. Das Laden des Modells dauert je nach
Größe zwischen 20 Sekunden und wenigen Minuten.

## 8. Projekte in Open WebUI

- Neuer Ordner in der Seitenleiste, über das Menü des Ordners
  **Bearbeiten**: Name, System-Prompt und Wissen festlegen.
- Wissen anlegen unter **Arbeitsbereich > Wissen**, Dateien hochladen und
  die Wissensbasis dem Ordner zuweisen.
- Chats in diesem Ordner erhalten automatisch System-Prompt und Wissen.

Empfehlungen für die CPU:

- Pro Thema einen neuen Chat beginnen. Der gesamte Verlauf wird bei jeder
  Antwort mitgeschickt und verlängert die Wartezeit.
- Bei Wissensbasen die Standard-Suche (RAG) verwenden, nicht den Modus mit
  vollem Kontext. Der volle Kontext sprengt schnell `CHAT_CTX`.
- Wenige, gezielte Dateien pro Projekt anhängen.

## 9. Modellwechsel (z.B. nach dem RAM-Ausbau)

In `setup.conf` die auskommentierten Zeilen für das größere Modell
aktivieren und den Kontext erhöhen:

```
CHAT_MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF
CHAT_MODEL_FILE=Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
CHAT_CTX=32768
```

Danach `./setup.sh` ausführen. Das Modell wird geladen, die Container werden
neu angelegt. Der Modellname in Open WebUI (`CHAT_ALIAS`) bleibt gleich,
Projekte und Standardmodell passen weiterhin. Das alte Modell kann danach
aus `MODELS_DIR` gelöscht werden.

## 10. Autovervollständigung in VS Code (optional)

```
# AUTOCOMPLETE=1 in setup.conf, danach:
./setup.sh
code --install-extension ggml-org.llama-vscode
```

Die Erweiterung nutzt standardmäßig `http://127.0.0.1:8012`. Das Angebot der
Erweiterung, llama.cpp zu installieren, ist abzulehnen, da der Server bereits
im Container läuft. Benötigt zusätzlich ca. 2 GB RAM.

## 11. Offline-Betrieb und Datenschutz

- Nach der Einrichtung ist keine Internetverbindung mehr nötig.
- `OFFLINE_MODE` und `--offline` unterbinden Downloads, blockieren aber keine
  Verbindungen. Für eine harte Trennung sind Firewall-Regeln nötig.
- Chats und hochgeladene Dateien liegen in `WEBUI_DATA_DIR`. Sensible Inhalte
  (z.B. Logs mit personenbezogenen Daten) nach der Analyse löschen.
- Ob vertrauliche Daten auf dem Rechner verarbeitet werden dürfen, regeln die
  internen Vorgaben, auch wenn das Modell lokal läuft.

## 12. Aktualisierung

```
./setup.sh --update
```

Lädt das in `WEBUI_IMAGE` angegebene Open-WebUI-Image und das
llama.cpp-Basis-Image neu und baut das llama-server-Image. Für eine neue
Version von Open WebUI zuerst `WEBUI_IMAGE` in `setup.conf` anpassen. Vor
einem Versionswechsel empfiehlt sich eine Sicherung von `WEBUI_DATA_DIR` bei
angehaltenen Containern (`./ctl.sh stop`).

## 13. Entfernen

| Befehl                        | Wirkung                          |
|-------------------------------|----------------------------------|
| `./cleanup.sh`                | alles entfernen                  |
| `./cleanup.sh --keep-models`  | Modelle behalten                 |
| `./cleanup.sh --keep-data`    | Daten von Open WebUI behalten    |
| `./cleanup.sh -y`             | ohne Abfrage                     |

Entfernt Container, Pod, Netzwerk, Images, Modelle, die Daten von Open WebUI
und die erzeugten Dateien. Laufen noch Container, werden sie angezeigt und es
folgt eine Abfrage (y/n). Ohne laufende Container erfolgt das Entfernen ohne
Rückfrage. Die Projektdateien selbst bleiben erhalten.

Liegt `MODELS_DIR` außerhalb des Projektverzeichnisses, werden dort nur die
konfigurierten Modelldateien gelöscht, nicht das ganze Verzeichnis.

## 14. Fehlersuche

**Prüfung der Voraussetzungen**

```
./setup.sh --check
```

**Logs**

```
./ctl.sh logs chat
./ctl.sh logs webui
less .local-coder.log
```

**Modell erscheint nicht in Open WebUI**

Der Chat-Container lädt noch das Modell. `./ctl.sh status` zeigt, ob er
bereit ist. Danach die Seite neu laden.

**"aardvark pid not found" bzw. Open WebUI erreicht den Chat nicht**

```
podman rm -f local-coder-chat local-coder-webui local-coder-fim
podman network rm local-coder_default
rm -rf /run/user/$(id -u)/containers/networks/aardvark-dns
./setup.sh
```

**Fehler "context size exceeded" im Chat**

Verlauf und Anhänge sind größer als `CHAT_CTX`. Neuen Chat beginnen, weniger
Dateien anhängen oder `CHAT_CTX` erhöhen (benötigt mehr RAM).

**Antworten brechen nach einigen Minuten ab**

`WEBUI_REQUEST_TIMEOUT` in `setup.conf` erhöhen, danach `./setup.sh`.

## 15. Umstieg vom bisherigen Stand

Der bisherige Stand nutzte die eingebaute Weboberfläche von llama-server auf
Port 8080 und eine `.env` aus `env.example`. Beim Umstieg:

- Die Dateien `env.example` und `download_models.sh` werden nicht mehr
  benötigt und können gelöscht werden.
- `setup.sh` sichert eine bestehende, nicht von `setup.sh` erzeugte `.env`
  als `.env.old` und erzeugt eine neue aus `setup.conf`.
- Vorhandene Modelle in `./models` werden weiter verwendet, sofern die
  Dateinamen in `setup.conf` übereinstimmen.
- Die Oberfläche ist jetzt unter <http://127.0.0.1:3000> erreichbar. Port 8080
  wird nicht mehr belegt. Eine Anbindung von VS-Code-Chat-Erweiterungen an
  Port 8080 (z.B. Continue) entfällt.
