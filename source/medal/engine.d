/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.engine;

import medal.config : Config;
import medal.logger;
import medal.message;
import medal.transition.core;

import std.algorithm : all, canFind;
import std.concurrency : LinkTerminated, Tid;
import std.json : JSONValue;
import std.range : byPair, empty;
import std.variant : Variant;

///
struct EngineWillStop
{
    BindingElement bindingElement;
}

///
immutable class EngineStopTransition_: Transition
{
    ///
    this(in Guard g) @nogc nothrow pure @safe
    {
        super("engine-stop", g, ArcExpressionFunction.init);
    }

    ///
    override void fire(in BindingElement be, Tid networkTid, Config config = Config.init, Logger logger = null) const
    {
        import std.concurrency : send;

        scope(success) logger.trace(oneShotMsg(be, config));
        scope(failure) logger.critical(failureMsg(be, config, "unknown error"));
        send(networkTid, EngineWillStop(be));
    }

    static JSONValue oneShotMsg(in BindingElement be, in Config con) pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "oneshot";
        ret["transition-type"] = "engine-stop";
        ret["tag"] = con.tag;
        ret["result"] = be.tokenElements.to!(string[string]);
        return ret;
    }

    static JSONValue failureMsg(in BindingElement be, in Config con, in string cause) pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "oneshot-failure";
        ret["transition-type"] = "engine-stop";
        ret["tag"] = con.tag;
        ret["result"] = be.tokenElements.to!(string[string]);
        ret["cause"] = cause;
        return ret;
    }
}

/// ditto
alias EngineStopTransition = immutable EngineStopTransition_;

///
struct Engine
{
    ///
    this(in Transition tr) nothrow pure @trusted
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.exception : assumeUnique;
        import std.typecons : tuple;

        auto g = tr.arcExpFun
                   .byKey
                   .map!(p => tuple(p, InputPattern(SpecialPattern.Any)))
                   .assocArray;
        this([tr], g.assumeUnique);
    }

    ///
    this(in Transition[] trs, in Guard stopGuard = Guard.init,
         in Transition[] exitTrs = [], in Transition[] successTrs = [],
         in Transition[] failureTrs = []) nothrow pure @safe
    in(!trs.empty)
    do
    {
        transitions = trs;
        if (!stopGuard.empty)
        {
            transitions ~= new EngineStopTransition(stopGuard);
        }
        store = Store(transitions);
        rule = Rule(transitions);
        exitRules = [
            ExitMode.success: Rule(exitTrs~successTrs),
            ExitMode.failure: Rule(exitTrs~failureTrs),
        ];
    }

    ///
    BindingElement run(in BindingElement initBe, Config config = Config.init, Logger logger = sharedLog)
    {
        import std.concurrency : receive, send, thisTid;
        import std.container.rbtree : RedBlackTree;
        import std.container.array : Array;
        import std.container.binaryheap : BinaryHeap;
        import std.container.util : make;
        import std.conv : to;
        import std.typecons : Rebindable;

        logger.trace(startMsg(initBe, config));
        scope(failure) logger.critical(failureMsg(initBe, config, "Unknown error"));

        if (!config.reuseParentTmpdir && !config.tmpdir.empty)
        {
            import std.file : exists, mkdirRecurse;
            if (config.tmpdir.exists)
            {
                logger.critical(failureMsg(initBe, config, "tmpdir already exists: "~config.tmpdir));
                return typeof(return).init;
            }
            // it will be deleted by root (app.main)
            mkdirRecurse(config.tmpdir);
        }

        auto running = true;
        // https://issues.dlang.org/show_bug.cgi?id=21512
        //auto trTids = make!(RedBlackTree!(Tid, (in Tid a, in Tid b) => a.to!string < b.to!string));
        Tid[string] trTids;
        Rebindable!(typeof(return)) ret;
        send(thisTid, TransitionSucceeded(initBe));
        while (running)
        {
            receive(
                (TransitionSucceeded ts) {
                    logger.trace(recvMsg(ts, config));
                    store.put(ts.tokenElements);
                    auto candidates = rule.dispatch(ts.tokenElements);
                    while (!candidates.empty)
                    {
                        import std.range : front, popFront;

                        auto c = candidates.front;
                        if (auto be = c.fireable(store))
                        {
                            store.remove(be);
                            auto tid = spawnFire(c, be, thisTid, config, logger);
                            //trTids.insert(tid);
                            trTids[tid.to!string] = tid;
                            logger.trace(fireMsg(c, be, tid, config));
                            continue;
                        }
                        candidates.popFront;
                    }
                },
                (TransitionFailed tf) {
                    logger.trace(recvMsg(tf, config));
                    store.put(tf.tokenElements);
                    running = false;
                },
                (in SignalSent sig) {
                    logger.trace(recvMsg(sig, config));
                    running = false;
                },
                (in EngineWillStop ews) {
                    logger.trace(recvMsg(ews, config));
                    ret = ews.bindingElement;
                    running = false;
                },
                (LinkTerminated lt) {
                    logger.trace(recvMsg(lt, config));
                    //trTids.removeKey(lt.tid);
                    trTids.remove(lt.tid.to!string);
                },
                (Variant v) {
                    import std.format : format;
                    auto msg = format!"unknown message (%s)"(v);
                    logger.critical(failureMsg(initBe, config, msg)); // TODO: fix
                    running = false;
                },
            );
        }

        killTransitions(trTids, logger);
        auto success = waitTransitions(trTids, logger, config);

        Rule exitRule = exitRules[!ret.empty && success ?
                                  ExitMode.success : ExitMode.failure];

        send(thisTid, TransitionSucceeded(new BindingElement));
        bool firstRun = true;
        while (!trTids.empty || firstRun)
        {
            receive(
                (TransitionSucceeded ts) {
                    firstRun = false;
                    logger.trace(recvMsg(ts, config));
                    store.put(ts.tokenElements);
                    auto candidates = exitRule.dispatch(ts.tokenElements);
                    while (!candidates.empty)
                    {
                        import std.range : front, popFront;

                        auto c = candidates.front;
                        if (auto be = c.fireable(store))
                        {
                            store.remove(be);
                            auto tid = spawnFire(c, be, thisTid, config, logger);
                            //trTids.insert(tid);
                            trTids[tid.to!string] = tid;
                            logger.trace(fireMsg(c, be, tid, config));
                            continue;
                        }
                        candidates.popFront;
                    }
                },
                (TransitionFailed tf) {
                    // it does not roll back to prevent eternal loops
                    logger.trace(recvMsg(tf, config));
                    // store.put(tf.tokenElements);
                },
                (in SignalSent sig) {
                    // ignored
                    logger.trace(recvMsg(sig, config));
                },
                (LinkTerminated lt) {
                    logger.trace(recvMsg(lt, config));
                    //trTids.removeKey(lt.tid);
                    trTids.remove(lt.tid.to!string);
                },
                (Variant v) {
                    import std.format : format;
                    auto msg = format!"unknown message (%s)"(v);
                    logger.critical(failureMsg(initBe, config, msg)); // TODO: fix
                },
            );
        }

        logger.trace(successMsg(ret, config));
        return ret;
    }

    void killTransitions(Tid[string] tids, Logger logger)
    {
        import std.array : array;

        logger.trace("Start sending kill msgs to ", tids.byValue.array);
        scope(exit) logger.trace("Finish sending kill msgs");

        foreach(t; tids.byValue)
        {
            import core.stdc.signal : SIGINT;
            import std.concurrency : send;

            logger.trace("Send kill to ", t);
            send(t, SignalSent(SIGINT));
        }
    }

    bool waitTransitions(ref Tid[string] tids, Logger logger, in Config con)
    out(_; tids.empty)
    {
        import std.array : array;

        logger.trace("Waiting transitions: ", tids.byValue.array);
        scope(exit) logger.trace("All transitions are rolled back");

        bool success = true;
        while (!tids.empty)
        {
            import std.concurrency : receive;
            receive(
                (TransitionSucceeded ts) {
                    logger.trace(ts, " received");
                    //logger.trace(recvMsg(ts, con));
                    store.put(ts.tokenElements);
                },
                (TransitionFailed tf) {
                    logger.trace(tf, " received");
                    //logger.trace(recvMsg(tf, con));
                    store.put(tf.tokenElements);
                    success = false;
                },
                (in SignalSent sig) {
                    logger.trace(sig, " received");
                    //logger.trace(recvMsg(sig, con)); // ignored
                },
                (in EngineWillStop ews) {
                    // TODO: how to deal with it?
                    logger.trace(ews, " received");
                    //logger.trace(recvMsg(ews, config));
                },
                (LinkTerminated lt) {
                    import std.conv : to;
                    logger.trace(lt, " received");
                    //logger.trace(recvMsg(lt, con));
                    tids.remove(lt.tid.to!string);
                },
                (Variant v) {
                    import std.format : format;
                    auto msg = format!"unknown message (%s)"(v);
                    //logger.critical(failureMsg(initBe, con, msg)); // TODO: fix
                    success = false;
                },
            );
        }
        return success;
    }

    JSONValue recvMsg(in TransitionSucceeded ts, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv";
        ret["tag"] = con.tag;
        ret["elems"] = ts.tokenElements.tokenElements.to!(string[string]);
        ret["success"] = true;
        ret["thread-id"] = (cast()ts.tid).to!string[4..$-1];
        return ret;
    }

    JSONValue recvMsg(in TransitionFailed tf, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv";
        ret["tag"] = con.tag;
        ret["elems"] = tf.tokenElements.tokenElements.to!(string[string]);
        ret["success"] = false;
        ret["thread-id"] = (cast()tf.tid).to!string[4..$-1];
        ret["cause"] = tf.cause;
        return ret;
    }

    JSONValue recvMsg(in SignalSent ss, in Config con) @trusted
    {
        import std.format : format;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv-signal";
        ret["tag"] = con.tag;
        ret["cause"] = format!"signal (%s) was caught"(ss.no);
        return ret;
    }

    JSONValue recvMsg(in EngineWillStop ews, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv-ews-msg";
        ret["tag"] = con.tag;
        ret["elems"] = ews.bindingElement.tokenElements.to!(string[string]);
        ret["success"] = true;
        return ret;
    }

    JSONValue recvMsg(LinkTerminated lt, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv-lt";
        ret["tag"] = con.tag;
        ret["success"] = true;
        ret["thread-id"] = lt.tid.to!string[4..$-1];
        return ret;
    }

    JSONValue startMsg(in BindingElement be, in Config con) pure @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "start";
        ret["tag"] = con.tag;
        ret["in"] = be.tokenElements.to!(string[string]);
        return ret;
    }

    JSONValue successMsg(in BindingElement be, in Config con) pure @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "end";
        ret["tag"] = con.tag;
        ret["out"] = be is null ? (string[string]).init : be.tokenElements.to!(string[string]);
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in Config con, in string cause = "") pure @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "end";
        ret["tag"] = con.tag;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    JSONValue fireMsg(in Transition tr, in BindingElement be, in Tid tid, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "fire";
        ret["tag"] = con.tag;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["transition"] = tr.name;
        ret["thread-id"] = (cast()tid).to!string[4..$-1];
        return ret;
    }

    Transition[] transitions;
    Store store;
    Rule rule;
    Rule[ExitMode] exitRules;

    enum ExitMode
    {
        success,
        failure,
    }
}

///
struct Store
{
    ///
    this(in Transition[] trs) nothrow pure @safe
    in(!trs.empty)
    do
    {
        import std.algorithm : each, filter;
        import std.range : chain;

        foreach(t; trs)
        {
            chain(t.guard.byKey,
                  t.arcExpFun.byKey).filter!(p => p !in state)
                                    .each!(p => state[p] = []);
        }
    }

    ///
    void put(in BindingElement be) pure @safe
    in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    do
    {
        foreach(p, t; be.tokenElements)
        {
            state[p] = state[p] ~ t;
        }
    }

    ///
    void remove(in BindingElement be)
    in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    in(be.tokenElements.byPair.all!(pt => state[pt[0]].canFind(pt[1])))
    do
    {
        import std.algorithm : findSplit;

        foreach(p, t; be.tokenElements)
        {
            auto split = state[p].findSplit([t]);
            state[p] = split[0] ~ split[2];
        }
    }

    string toString() const pure @safe
    {
        import std.conv : to;
        return state.to!string;
    }
    const(Token)[][Place] state;
}

///
@safe struct Rule
{
    ///
    this(in Transition[] trs) @nogc nothrow pure
    {
        transitions = trs;
    }

    ///
    auto dispatch(BindingElement trigger) const
    {
        return transitions[];
    }

    Transition[] transitions;
}
