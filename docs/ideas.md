## Einstieg in die KI
Ich habe für oracle pl/sql ein Framework für das Logging und Monitoring von PL/SQL Anwendungen entwickelt: LILA (LILA Integrated Logging Architecture) - github.com/dirkgermany/LILA-Logging/README.md, nicht zu verwechseln mit einem ähnlich klingenden Framework, das für die Entwicklung verwendet wird.

Es gibt keine Konfigurationsdateien bzw. Tabellen.
Bis auf einige wenige notwendige Grants läuft LILA OOTB.
Das Logging und das Monitoring schreiben in zwei Tabellen: 'Master' mit dem Zustand je Log-Session, 'Detail' mit Logs und Monitor-Markern.
Default-Name der Master ist 'LILA_LOG'. Die Detail Tabelle verwendet immer den Namen der Master || '_DETAIL'. Also heißt die Default-Detail Tabelle LILA_LOG_DETAIL.
Jede Log-Session kann bei Bedarf eigene Tabellen verwenden.

Je Log-Session existiert exakt ein Eintrag in der Master-Tabelle. Die IDs der Log-Sessions werden durch eine Sequence vergeben. Das ist die Referenz-ID, die in der Detail-Tabelle und bei Aufrufen der API verwendet wird.

LILA funktioniert in zwei alternativen Betriebsmodi:
'standalone', das heißt, man ruft die Methoden der API auf und nach der entspr. Bearbeitung kann die aufrufende Anwendung ihre Arbeit fortsetzen. Durch diverse Optimierungen (buffered sessions, buffered logs, buffered monitor-entries) wird die aufrufende Anwendung so gut wie nicht gebremst.

Gleichzeitig kann LILA als Server gestartet werden. Dann werden die Kommandos der API per Signal aufgerufen und - ja nach Befehl - per Alert auf eine Antwort gewartet oder auch nicht.
Das gesamte Handling der Kommunikation mit dem Server läuft innerhalb der API, d.h. die Aufrufe der Remote-API stellt sich genauso dar, wie die für die Standalone-API

LILA arbeitet mit autonomen Transaktionen (silent mode).
So ist sichergestellt, dass die Anwendung stabil läuft.
Die Buffered-Mechanismen arbeiten auf Basis von Mengen-Thresholds und Zeit-Thresholds.

Damit sich LILA als ein einziges Tool für die unterschiedlichsten Szenarien präsentiert, ist der gesamte Code in einem Paket (.pks + .pkb).


## Wichtig für MARK_STEP und STEP_DONE
Problem: Wenn die Pipe (wie neulich) voll ist oder der Server 3 Sekunden "schläft", verfälscht die Wartezeit in der Pipe die avg_action_time, wenn der Server erst beim Auspacken den Zeitstempel nimmt.
Lösung: Der Client sollte beim MARK_STEP seinen lokalen Zeitstempel (SYSTIMESTAMP) mit in die Pipe packen. Der Server nutzt diesen Wert für die Differenzberechnung. So misst du die echte Business-Logik-Zeit und nicht die Infrastruktur-Latenz.

## Hinweis auf Multi-Channel-Logging
LILA kann im Parallelbetrieb (standalone und remote zugleich) arbeiten.

### Standard-Logs (Low Priority)
standalone und gepuffert in die lokale DB schreiben
### Kritische Monitoring-Events (High Priority)
zeitgleich remote an den LILA-Server senden, damit dort sofort Alarme ausgelöst werden können, ohne auf den nächsten lokalen Buffer-Flush zu warten.


## Flushs auslagern in den Server-Loop

## Adaptive Timeouts: 
In Oracle 23ai kannst du die Flush-Intervalle dynamisch an die Last anpassen. Wenn der Dirty-Zähler sehr schnell steigt, verkürzt LILA das Zeit-Intervall automatisch.

##Sicherheit des Buffers: 
Falls die Session hart abbricht (z.B. ORA-00600), gehen gepufferte Daten verloren. Für extrem kritische Anwendungen könntest du einen SESSION_CLEANUP-Trigger in Betracht ziehen, der beim Beenden der Session (auch abnormal) einen letzten Not-Flush versucht.

### Lösung: Der System-Trigger (ON LOGOFF)
Du kannst LILA noch "runder" machen, indem du ein fertiges Snippet für einen AFTER LOGOFF ON SCHEMA Trigger in deine Dokumentation/Installation packst.
So würde ein solcher Sicherheits-Trigger für LILA aussehen:

Du könntest eine Prozedur lila.enable_safety_trigger anbieten, die das dynamisch per EXECUTE IMMEDIATE erledigt.
Warum das Monitoring davon profitiert:
Wenn ein Prozess hart abstürzt, bleibt bei vielen Frameworks der Status in der Monitoring-Tabelle auf "Running" stehen (eine "Leiche"). Mit dem Logoff-Flush oder einem Cleanup-Trigger kannst du den Status beim Abbruch der Verbindung automatisch auf "ABORTED" setzen. Das macht dein Monitoring-Level (Level 3) wesentlich zuverlässiger.

## Server-Seitige Absicherung (Dead Session Cleanup):
Da Clients (trotz bester Dokumentation) manchmal einfach „sterben“ (z. B. Netzwerkabbruch, Timeout), ohne CLOSE_SESSION zu rufen, wäre eine "Zombie-Logik" im Server das i-Tüpfelchen:
1. Prüfe beim regelmäßigen Timer-Flush, ob Sessions seit X Stunden inaktiv sind.
2. Falls ja: Automatisch flushen und die Session im Speicher löschen.

## Die Singleton-Herausforderung (Server-Lock)
Damit nicht zwei Prozesse gleichzeitig DBMS_ALERT.WAITONE auf denselben Kanal machen (was zu unvorhersehbarem Verhalten führt), ist DBMS_LOCK (oder in neueren Versionen DBMS_APPLICATION_INFO) dein Freund.
### Einfachste Lösung:
Bevor der LOOP startet, versucht der Server einen exklusiven Lock zu setzen:
```sql
l_lock_result := DBMS_LOCK.REQUEST(
    lockhandle => l_lock_handle,
    lockmode   => DBMS_LOCK.X_MODE,
    timeout    => 0, -- Sofort fehlschlagen, wenn besetzt
    release_on_commit => FALSE
);

IF l_lock_result != 0 THEN
    raise_application_error(-20001, 'LILA-Server läuft bereits.');
END IF;
```

## Mehrere parallele LILA-Server
Ist es ein sinnvolles und in der Praxis gefordertes Szenario, dass mehrere LILA-Server gleichzeitig laufen?
Ich habe überlegt, dass man im START_SERVER Aufruf einen Namen des Servers mitgibt. Das wäre gleichzeitig die Pipe oder ein Teil davon, auf den der Server lauscht.
Optional könnte im Aufruf NEW_SESSION der Parameter dieses Namens mitgegeben werden und der Name als Teil von t_session_rec hinterlegt werden.
Bei jedem Client-Aufruf der API könnte so überprüft werden, ob der Parameter gesetzt ist und wenn ja, würde die Kommunikation mit dem gewünschten Server erfolgen.

### Enterprise-Readiness
#### Workload-Isolation
Du kannst einen Server für "High-Volume Traffic" (z. B. ETL-Prozesse) und einen zweiten für "Business-Critical Logs" (z. B. Finanz-Transaktionen) reservieren. Ein "voller" ETL-Server würde dann nicht die kritischen Logs blockieren.
#### Mandantenfähigkeit
Unterschiedliche Applikationen im selben DB-Schema können ihre eigenen Logging-Instanzen steuern, ohne sich gegenseitig in die Pipe-Quere zu kommen.
#### Horizontal Skalierung
Wenn eine Instanz trotz FORALL am I/O-Limit klebt, können zwei Server auf unterschiedlichen Pipes parallel in die Tabelle schreiben.

Das ist ein absolut realistischer Business-Case, auch wenn er sich erst in größeren Umgebungen voll entfaltet. In der Praxis begegnen dir drei Szenarien, in denen du für diese
#### Skalierbarkeit
##### Dienstgüte (SLA)
Ein riesiger Datenimport schreibt 10 Millionen Logs und "verstopft" die Pipe. Gleichzeitig läuft ein wichtiger Web-Service-Call, der nur 5 Logs schreibt, diese aber sofort im Monitor sehen muss. Ohne Trennung müsste der Web-Service warten, bis der Import-Server die 16 MB abgearbeitet hat.
##### Applikations-Silos
In großen Firmen nutzen oft verschiedene Teams dieselbe Datenbank. Team A möchte seine Logs nach 7 Tagen löschen, Team B braucht sie für Compliance 10 Jahre. Mit zwei Server-Instanzen (und unterschiedlichen Zieltabellen oder Flags) lässt sich das ohne Code-Änderung steuern.
##### Debug-Isolierung
Du kannst einen speziellen "Trace-Server" starten, der nur für eine einzige Session im DEBUG-Modus läuft, während der Haupt-Server für alle anderen weiterhin nur WARN/ERROR verarbeitet. Das schont die Performance der Gesamtanwendung.

### Einordnung der Begriffe für LILA und im IT-Business-Kontext
#### Workload-Isolation (Betriebssicherheit)
Das fällt unter Verfügbarkeit (Availability) und Stabilität.
Ziel: Verhindern, dass ein "Nachbar" das System lahmlegt.
Beispiel: Ein fehlerhafter Batch-Job flutet die Pipe mit Millionen von Logs. Durch die Isolation auf einen eigenen Server bleibt der Logging-Kanal für die Online-User (Webshop) frei. Ein Problem in Bereich A darf Bereich B nicht beeinflussen.
#### Mandantenfähigkeit (Multi-Tenancy)
Das fällt unter Datenhaltung (Data Segregation) und Sicherheit.
Ziel: Strikte Trennung von Daten und Konfiguration zwischen verschiedenen Kunden oder Abteilungen.
Beispiel: Server "KUNDE_A" schreibt in Schema_A, Server "KUNDE_B" in Schema_B. Keiner sieht die Logs des anderen. In der Cloud oder bei Shared-Database-Modellen ist das die Grundvoraussetzung, um rechtliche Vorgaben (DSGVO/Compliance) einzuhalten.
#### Horizontale Skalierung (Scale-Out)
Das fällt unter Durchsatz (Performance).
Ziel: Die Leistung durch Hinzufügen weiterer Einheiten erhöhen, anstatt eine einzelne Einheit immer größer zu machen (Vertical Scaling / Up).
Beispiel: Ein einzelner LILA-Server schafft 10.000 Logs/s, weil die CPU eines Prozesses am Limit ist. Du startest drei LILA-Server parallel, verteilst die Last und schaffst plötzlich 30.000 Logs/s.


