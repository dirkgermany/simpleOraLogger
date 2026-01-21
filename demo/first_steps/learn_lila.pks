create or replace PACKAGE LEARN_LILA as 

    -- First steps
    procedure simple_sample;
    -- Start session, stop session
    procedure begin_and_end_with_steps;
    -- Start session, increment steps, write number of completed steps to dbms_output, stop session
    procedure increment_steps_and_monitor;
    -- Start session with initial data, return data, stop session
    -- This function can be used within a select statement:
    -- "select learn_lila.print_process_infos from dual;"
    function print_process_infos return varchar2;
    
end LEARN_LILA;
