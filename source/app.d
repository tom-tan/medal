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
    sharedLog = new JSONLogger(stderr, LogLevel.info);
    string initFile;
    auto helpInfo = args.getopt(
        std.getopt.config.caseSensitive,
        "init|i", "Specify initial marking file", &initFile,
        "quiet", () => sharedLog.logLevel = LogLevel.off,
    );
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
        sharedLog.critical("Network file is not found: "~netFile);
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
        sharedLog.critical("Initial marking file is not found: "~initFile);
        return 1;
    }

    auto mainTid = spawnFire(tr, initBe, thisTid, sharedLog);

    bool success;
    receive(
        (TransitionSucceeded ts) {
            sharedLog.info("Received: ", ts);
            success = true;
        },
        (TransitionFailed tf) {
            sharedLog.info("Failed.");
            success = false;
        },
        (SignalSent ss) {
            sharedLog.info("Signal %s is caught", ss.no);
            success = false;
        },
        (shared Throwable e) {
            sharedLog.criticalf("Exception in %s(%s): %s", e.file, e.line, e.msg);
            success = false;
        },
        (Variant v) {
            sharedLog.critical("Error: ", v);
            success = false;
        },
    );
    return success ? 0 : 1;
}
