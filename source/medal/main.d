/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.main;

import dyaml : YAMLException;

import medal.exception : LoadError;
import medal.logger : Logger;
import medal.message : TransitionSucceeded;

import std.concurrency : Tid;
import std.json : JSONValue;

int medalMain(string[] args)
{
    import dyaml : Loader, Node;
    import medal.config : Config;
    import medal.loader : loadBindingElement, loadTransition;
    import medal.logger : JSONLogger, LogLevel, LogType, sharedLog;
    import medal.message : SignalSent, TransitionInterrupted, TransitionFailed;
    import medal.transition.core : BindingElement, spawnFire, Transition;
    import std.concurrency : receive, thisTid;
    import std.file : exists, mkdirRecurse;
    import std.format : format;
    import std.getopt : config, getopt;
    import std.path : absolutePath;
    import std.range : empty;
    import std.stdio : File, stderr;
    import std.typecons : Rebindable;
    import std.variant : Variant;

    auto appLv = LogLevel.info;
    auto sysLv = LogLevel.info;
    Logger[LogType] loggers;
    string initFile;
    string appLogFile;
    string sysLogFile;
    string tmpdir;
    bool leaveTmpdir;
    string workdir;

    auto helpInfo = args.getopt(
        config.caseSensitive,
        "init|i", "Specify initial marking file", &initFile,
        "sys-quiet", "Do not print any system logs", () { sysLv = LogLevel.off; },
        "sys-verbose", "Enable verbose system logs", () { sysLv = LogLevel.trace; },
        "sys-log", "Specify system log destination (default: stderr)", &sysLogFile,
        "app-quiet", "Do not print any application logs", () { appLv = LogLevel.off; },
        "app-verbose", "Enable verbose application logs", () { appLv = LogLevel.trace; },
        "app-log", "Specify application log destination (default: stderr)", &appLogFile,
        "quiet", "Same as `--sys-quiet --app-quiet`", () { sysLv = appLv = LogLevel.off; },
        "verbose", "Same as `--sys-verbose --app-verbose`", () { sysLv = appLv = LogLevel.trace; },
        "log", "Same as `--sys-log=file --app-log=file`", (string _, string name) { sysLogFile = appLogFile = name; },
        "tmpdir", "Specify temporary directory", &tmpdir,
        "leave-tmpdir", "Leave temporary directory after execution", &leaveTmpdir,
        "workdir", "Specify working directory", &workdir,
    );

    if (helpInfo.helpWanted || args.length != 2)
    {
        import std.getopt : defaultGetoptPrinter;
        import std.path : baseName;
        import std.string : outdent;

        immutable baseMessage = format!(q"EOS
            Medal: A workflow engine based on Petri nets
            Usage: %s [options] <network.yml>
EOS".outdent[0..$-1])(args[0].baseName);
        defaultGetoptPrinter(baseMessage, helpInfo.options);
        return 0;
    }

    if (sysLogFile == appLogFile)
    {
        auto f = sysLogFile.empty ? stderr : File(sysLogFile, "w");
        loggers[LogType.System] = new JSONLogger(f, sysLv);
        loggers[LogType.App] = new JSONLogger(f, appLv);
    }
    else
    {
        auto sf = sysLogFile.empty ? stderr : File(sysLogFile, "w");
        loggers[LogType.System] = new JSONLogger(sf, sysLv);

        auto af = appLogFile.empty ? stderr : File(appLogFile, "w");
        loggers[LogType.App] = new JSONLogger(af, appLv);
    }
    sharedLog = loggers[LogType.System];

    if (tmpdir.empty)
    {
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        tmpdir = buildPath(tempDir, format!"medal-%s"(thisProcessID)).absolutePath;
        if (tmpdir.exists)
        {
            sharedLog.critical(failureMsg("Temporary directory already exists: "~tmpdir));
            return 1;
        }
    }
    else
    {
        tmpdir = tmpdir.absolutePath;
        if (tmpdir.exists)
        {
            sharedLog.critical(failureMsg("Specified temporary directory already exists: "~tmpdir));
            return 1;
        }
    }
    mkdirRecurse(tmpdir);
    scope(exit)
    {
        if (!leaveTmpdir)
        {
            import std.file : rmdirRecurse;
            rmdirRecurse(tmpdir);
        }
    }

    workdir = workdir.absolutePath;
    if (!workdir.empty && !workdir.exists)
    {
        sharedLog.critical(failureMsg("Specified working directory does not exist: "~workdir));
        return 1;
    }

    Config con = {
        tmpdir: tmpdir, workdir: workdir,
        leaveTmpdir: leaveTmpdir, reuseParentTmpdir: true,
    };

    auto netFile = args[1];
    if (!netFile.exists)
    {
        sharedLog.critical(failureMsg("Network file is not found: "~netFile));
        return 1;
    }
    Node netRoot;
    Rebindable!Transition tr;
    try
    {
        netRoot = Loader.fromFile(netFile).load;
        tr = loadTransition(netRoot);
    }
    catch(LoadError e)
    {
        sharedLog.critical(failureMsg(e));
        return 1;
    }
    catch(YAMLException e)
    {
        sharedLog.critical(failureMsg(e));
        return 1;
    }

    Rebindable!BindingElement initBe;
    if (initFile.exists)
    {
        Node initRoot = Loader.fromFile(initFile).load;
        initBe = loadBindingElement(initRoot);
    }
    else if (initFile.empty)
    {
        initBe = new BindingElement;
    }
    else
    {
        sharedLog.critical(failureMsg("Initial marking file is not found: "~initFile));
        return 1;
    }

    if (!tr.fireable(initBe))
    {
        sharedLog.critical(failureMsg("Initial marking does not match the guard of the network"));
        return 1;
    }

    auto handlerTid = spawnSignalHandler(sharedLog);
    scope(exit)
    {
        import core.sys.posix.signal : kill, SIGQUIT;
        import std.process : thisProcessID;

        kill(thisProcessID, SIGQUIT);
    }
    auto mainTid = spawnFire(tr, initBe, thisTid, con, loggers);

    bool success;
    receive(
        (TransitionSucceeded ts) {
            sharedLog.info(successMsg(ts));
            success = true;
        },
        (TransitionFailed tf) {
            sharedLog.info(failureMsg("transition failure"));
            success = false;
        },
        (SignalSent ss) {
            import std.concurrency : send;

            auto no = ss.no;
            sharedLog.info(failureMsg(format!"signal %s is sent"(no)));
            send(mainTid, ss);
            receive(
                (TransitionSucceeded ts) {
                    sharedLog.info(successMsg(ts));
                    success = true;
                },
                (TransitionFailed tf) {
                    sharedLog.info(failureMsg("transition failure"));
                    success = false;
                },
                (TransitionInterrupted ti) {
                    sharedLog.info(failureMsg(format!"transition is interrupted (%s)"(no)));
                    success = false;
                },
                (Variant v) {
                    auto msg = format!"Unintended object is received after signal interrupt (%s): %s"(no, v);
                    sharedLog.critical(failureMsg(msg));
                    success = false;
                },
            );
        },
        (Variant v) {
            sharedLog.critical(failureMsg(format!"Unintended object is received: %s"(v)));
            success = false;
        },
    );
    return success ? 0 : 1;
}

JSONValue successMsg(in TransitionSucceeded ts)
{
    import std.conv : to;

    JSONValue ret;
    ret["sender"] = "medal";
    ret["success"] = true;
    ret["result"] = ts.tokenElements.tokenElements.to!(string[string]);
    return ret;
}

JSONValue failureMsg(in string cause)
{
    JSONValue ret;
    ret["sender"] = "medal";
    ret["success"] = false;
    ret["cause"] = cause;
    return ret;
}

JSONValue failureMsg(in YAMLException e)
{
    JSONValue ret;
    ret["sender"] = "medal.loader";
    ret["success"] = false;
    ret["cause"] = e.msg;
    ret["file"] = e.file;
    return ret;
}

JSONValue failureMsg(in LoadError e)
{
    JSONValue ret;
    ret["sender"] = "medal.loader";
    ret["success"] = false;
    ret["cause"] = e.msg;
    ret["file"] = e.file;
    ret["line"] = e.line;
    ret["column"] = e.column;
    return ret;
}

///
Tid spawnSignalHandler(Logger logger)
{
    import core.sys.posix.signal : sigaddset, sigemptyset, pthread_sigmask, sigset_t,
                                   SIGINT, SIGQUIT, SIGTERM, SIG_BLOCK;

    import medal.exception : SignalException;

    import std.concurrency : spawn;
    import std.exception : enforce;

    sigset_t ss;
    enforce!SignalException(sigemptyset(&ss) == 0);
    enforce!SignalException(sigaddset(&ss, SIGINT) == 0);
    enforce!SignalException(sigaddset(&ss, SIGTERM) == 0);
    enforce!SignalException(sigaddset(&ss, SIGQUIT) == 0);
    enforce!SignalException(pthread_sigmask(SIG_BLOCK, &ss, null) == 0);

    auto tid = spawn((sigset_t ss, shared Logger l) {
        Logger logger = cast()l;
        scope(success) logger.trace("Handler succeeded");
        scope(failure) logger.critical("Handler failed");

        int signo;
        while (true)
        {
            import core.sys.posix.signal : sigwait;
            import std.concurrency : send, ownerTid;

            logger.trace("Waiting signals...");
            auto ret = sigwait(&ss, &signo);
            if (ret == 0)
            {
                import medal.message : SignalSent;
                logger.trace("Recv: ", signo);
                if (signo == SIGQUIT)
                {
                    // SIGQUIT is used to quit this thread
                    logger.trace("break");
                    break;
                }
                send(ownerTid, SignalSent(signo));
            }
            else
            {
                logger.critical("Fail to recv");
                send(ownerTid, new immutable SignalException("sigwait failed"));
                break;
            }
        }
        logger.trace("Finish waiting signals");
    }, ss, cast(shared)logger);

    return tid;
}
