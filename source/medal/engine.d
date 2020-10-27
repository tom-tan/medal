module medal.engine;

import medal.transition;

import std;


struct EngineWillStop
{
    BindingElement bindingElement;
}

///
class Engine
{
    ///
    this(in Transition[] trs)
    in(!trs.empty)
    do
    {
        transitions = trs;
        store = new Store(trs);
        rule = new Rule(trs);
    }

    ///
    void run(in BindingElement initBe, Tid networkTid)
    {
        auto running = true;
        send(thisTid, initBe);
        while(running)
        {
            receive(
                (in BindingElement be) {
                    store.put(be);
                    foreach(tr; rule.transitions)
                    {
                        if (auto nextBe = tr.fireable(store))
                        {
                            store.remove(nextBe);
                            spawn((in Transition t, in BindingElement be) => t.fire(be, ownerTid),
                                  tr, nextBe);
                        }
                    }
                },
                (in SignalSent sig) {
                    // send sig to all transitions
                    running = false;
                },
                (in EngineWillStop ews) {
                    // send sig? to all transitions
                    send(networkTid, ews.bindingElement);
                    running = false;
                },
                (Variant v) {
                    running = false;
                },
            );
        }
    }

    Transition[] transitions;
    Store store;
    Rule rule;
}

class Store
{
    this(in Transition[] trs) pure
    {
    }

    ///
    void put(in BindingElement be) pure
    //in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    do
    {
        foreach(p, t; be.tokenElements)
        {
            auto tokens = state.get(p, []);
            state[p] = tokens ~ t;
        }
    }

    ///
    void remove(in BindingElement be)
    in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    in(be.tokenElements.byPair.all!(pt => state[pt[0]].canFind(pt[1])))
    do
    {
        foreach(p, t; be.tokenElements)
        {
            auto tokens = p in state;
            auto split = (*tokens)[].findSplit([t]);
            state[p] = split[0] ~ split[2];
        }
    }

    // `dispatch(BindingElement) const pure` needs much duplication cost...

    override string toString() const pure
    {
        return state.to!string;
    }
    const(Token)[][Place] state;
}

class Rule
{
    this(in Transition[] trs) pure
    {
        transitions = trs;
    }

    /+
    auto dispatch(Store store, BindingElement trigger) const pure
    {
        return transitions.map!(t => t.fireable(store))
                          .filter!(tuple => !tuple.isNull)
                          .map!(tuple => tuple.get)
                          .array;
        // return tuple(Transition, BindingElement)[]
    }+/

    Transition[] transitions;
}
