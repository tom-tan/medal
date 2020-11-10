/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
import medal.message : TransitionSucceeded;
import std.json : JSONValue;

int main(string[] args)
{
    import dyaml : Loader, Node;
    import medal.config : Config;
    import medal.loader : loadBindingElement, loadTransition;
    import medal.logger : JSONLogger, LogLevel, sharedLog;
    import medal.message : SignalSent, TransitionFailed;
    import medal.transition.core : BindingElement, spawnFire;
    import std.concurrency : receive, thisTid;
    import std.file : exists, mkdirRecurse;
    import std.format : format;
    import std.getopt : config, getopt;
    import std.range : empty;
    import std.stdio : stderr;
    import std.typecons : Rebindable;
    import std.variant : Variant;

    LogLevel lv = LogLevel.info;
    string initFile;
    string logFile;
    string tmpdir;
    bool leaveTmpdir;
    string workdir;

    auto helpInfo = args.getopt(
        config.caseSensitive,
        "init|i", "Specify initial marking file", &initFile,
        "quiet", "Do not print any logs", () { lv = LogLevel.off; },
        "debug", "Enable debug logs", () { lv = LogLevel.trace; },
        "log", "Specify log destination (default: stderr)", &logFile,
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

    if (logFile.empty)
    {
        sharedLog = new JSONLogger(stderr, lv);
    }
    else
    {
        sharedLog = new JSONLogger(logFile, lv);
    }

    if (tmpdir.empty)
    {
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        tmpdir = buildPath(tempDir, format!"medal-%s"(thisProcessID));
        if (tmpdir.exists)
        {
            sharedLog.critical(failureMsg("Temporary directory already exists: "~tmpdir));
            return 1;
        }
    }
    else
    {
        if (tmpdir.exists)
        {
            sharedLog.critical(failureMsg("Specified temporary directory already exists: "~tmpdir));
            return 1;
        }
    }
    mkdirRecurse(tmpdir);
    scope(exit) {
        if (!leaveTmpdir)
        {
            import std.file : rmdirRecurse;
            rmdirRecurse(tmpdir);
        }
    }

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
    Node netRoot = Loader.fromFile(netFile).load;
    auto tr = loadTransition(netRoot, netFile);

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

    auto mainTid = spawnFire(tr, initBe, thisTid, con, sharedLog);

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
            sharedLog.info(failureMsg(format!"signal %s is sent"(ss.no)));
            success = false;
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
