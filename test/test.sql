drop table test_log_detail purge;
drop table lila_log purge;
drop table lila_log_detail purge;
drop table local_log purge;
drop table local_log_detail purge;
drop table remote_log purge;
drop table remote_log_detail purge;

exec lila.SERVER_SEND_EXIT('{"msg":"okay"}');


DECLARE
    -- Falls die Funktion einen Wert zurückgibt, hier Variable deklarieren
    v_sessionRemote_id VARCHAR2(100);
    v_sessionLokal_id VARCHAR2(100);
BEGIN
    -- 1. Erstes Statement

    -- 2. Aufruf der Funktion und Zuweisung (:= statt =)
    dbms_output.put_line('Öffne eine remote session...');
    v_sessionRemote_id := lila.server_new_session('{"process_name":"Remote Session","log_level":8,"steps_todo":3,"days_to_keep":3,"tabname_master":"remote_log"}');
    dbms_output.put_line('Session remote: ' || v_sessionRemote_id);

    dbms_output.put_line('Öffne eine lokale session...');
    v_sessionLokal_id := lila.new_session('Local Session', 8, 'local_log');
    dbms_output.put_line('Session lokal: ' || v_sessionLokal_id);
   
    for i in 1..1000 loop
        lila.info(v_sessionLokal_id, 'Eine lokale Information');
        lila.info(v_sessionRemote_id, 'Eine remote Information');
    end loop;
   
    lila.close_session(v_sessionRemote_id);
    lila.close_session(v_sessionLokal_id);

END;
/

select 'local' modus, count(*) from local_log_detail
union
select 'remote' modus, count(*) from remote_log_detail;
