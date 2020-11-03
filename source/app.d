/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
import std;
import std.experimental.logger;

import dyaml;

import medal.loader;
import medal.transition;

import medal.logger;

int main(string[] args)
{
    LogLevel lv = LogLevel.info;
    string initFile;
    string logFile;
    auto helpInfo = args.getopt(
        std.getopt.config.caseSensitive,
        "init|i", "Specify initial marking file", &initFile,
        "quiet", "Do not print any logs", () { lv = LogLevel.off; },
        "debug", "Enable debug logs", () { lv = LogLevel.trace; },
        "log", "Specify log destination (default: stderr)", &logFile,
    );
    if (logFile.empty)
    {
        sharedLog = new JSONLogger(stderr, lv);
    }
    else
    {
        sharedLog = new JSONLogger(logFile, lv);
    }

    if (helpInfo.helpWanted || args.length != 2)
    {
        immutable baseMessage = format(q"EOS
        Medal: A workflow engine based on Petri nets
        Usage: %s [options] <network.yml>
EOS".outdent[0..$-1], args[0]);
        defaultGetoptPrinter(baseMessage, helpInfo.options);
        return 0;
    }

    auto netFile = args[1];
    if (!netFile.exists)
    {
        sharedLog.critical(failureMsg("Network file is not found: "~netFile));
        return 1;
    }
    Node netRoot = Loader.fromFile(netFile).load;
    auto tr = loadTransition(netRoot);

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

    auto mainTid = spawnFire(tr, initBe, thisTid, sharedLog);

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
