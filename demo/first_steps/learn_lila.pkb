create or replace PACKAGE BODY LEARN_LILA AS

    /*
        First steps:
        * open logging session
        * use dedicated log table
        * log with level info
        * write status of process
        * close logging session
    */
    procedure simple_sample
    as
        lProcessId number(19,0);
    begin
        -- use named params for this first time API call
        lProcessId := lila.new_session(
            p_processName   => 'simple sample',
            p_logLevel      => lila.logLevelInfo,
            p_daysToKeep    => 1,
            p_tabNameMaster => 'learn_lila_log'
        );
        lila.info(lProcessId, 'simple sample little step');
        lila.set_process_status(lProcessId, 1, 'Perfect!');
        lila.close_session(lProcessId);
    end;

    -- Shows how an application can be monitored.
    -- For simplicity, this example uses dbms_output. Therefore, please activate the DBMS_OUTPUT window.
    -- Starts without steps, sets steps_todo after starting and increments the completed steps
    -- No detail will be written
    procedure increment_steps_and_monitor
    as
        lProcessId number(19,0);
    begin
        dbms_output.enable();
        -- new log session
        lProcessId := lila.new_session(
            p_processName => 'cycle with steps',
            p_logLevel    => lila.logLevelInfo,
            p_daysToKeep  => 1
        );
        dbms_output.put_line('New log session ID: ' || lProcessId);

        -- Update process/application information (monitoring info)
        -- Alternatively, the number of expected steps could have been specified using the new_session function
        lila.set_steps_todo(lProcessId, 10);
        dbms_output.put_line('Steps To Do: ' || lila.get_steps_todo(lProcessId));

        -- monitor when a work step has been completed
        for i in 1..9 loop
            -- update process status
            lila.step_done(lProcessId);
            dbms_output.put_line('Some step completed: ' || i);
        end loop;
        
        lila.close_session(lProcessId, null, null, 'Too little', 4);
        dbms_output.put_line('Log session finished and closed');
        dbms_output.put_line('Process Status: ' || lila.get_process_status(lProcessId));
        dbms_output.put_line('Process Info  : ' || lila.get_process_info(lProcessId));
        dbms_output.put_line('Process Start : ' || lila.get_process_start(lProcessId));
        dbms_output.put_line('Process End   : ' || lila.get_process_end(lProcessId));
        dbms_output.put_line('Steps Done    : ' || lila.get_steps_done(lProcessId));
    end;


    -- Starts with a number of steps, ends with a number of steps processed
    -- No detail will be written
    procedure begin_and_end_with_steps
    as
        lProcessId number(19,0);
    begin
        lProcessId := lila.new_session('begin and end with steps', 10, lila.logLevelInfo, 1);
        lila.close_session(lProcessId, null, 11, 'Too much', 4);
    end;

    -- Call this function within a select statement:
    -- select learn_lila.print_process_infos from dual;
    function print_process_infos return varchar2
    as
        lProcessId number(19,0);
    begin
        lProcessId := lila.new_session(
            p_processName => 'print_process_infos',
            p_logLevel    => lila.logLevelInfo,
            p_stepsToDo   => 41,
            p_daysToKeep  => 1
        );            
        lila.close_session(
            p_processId   => lProcessId,
            p_stepsToDo   => null,
            p_stepsDone   => 42,
            p_processInfo => 'Response',
            p_status      => 7
        );

        return 'Process Informations: ID = ' || lProcessId || '; Status: ' || lila.get_process_status(lProcessId) || '; Info: ' || lila.get_process_info(lProcessId) || '; Steps todo: ' || lila.get_steps_todo(lProcessId) || '; Steps done: ' || lila.get_steps_done(lProcessId) || '; Start: ' || lila.get_process_start(lProcessId) || '; End: ' || lila.get_process_end(lProcessId);
    end;
END LEARN_LILA;
