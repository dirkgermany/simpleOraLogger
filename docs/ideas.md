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

