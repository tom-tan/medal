/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.config;

/**
 * Configuration shared within an Engine and its transitions
 */
@safe struct Config_
{
    /// a tag to distinguish the network
    string tag;

    /// environment variables
    string[string] environment;

    ///
    string workdir;

    ///
    string tmpdir;

    ///
    bool leaveTmpdir;

    ///
    bool reuseParentTmpdir;

    ///
    Config inherits(Config parent, bool inheritReuse = false) inout pure @trusted
    {
        import std.algorithm : canFind, either, merge, sort;
        import std.array : array, assocArray, byPair, replace;
        import std.exception : assumeUnique;
        import std.functional : not;
        import std.range : empty;

        string t;
        if (tag.canFind("~(tag)"))
        {
            t = tag.replace("~(tag)", parent.tag);
        }
        else
        {
            t = either!(not!empty)(parent.tag, tag);
        }
        auto wdir = either!(not!empty)(workdir.replace("~(workdir)", parent.workdir),
                                       parent.workdir);
        auto tdir = either!(not!empty)(tmpdir.replace("~(tmpdir)", parent.tmpdir)
                                             .replace("~(workdir)", parent.workdir),
                                       parent.tmpdir);
        // TODO: overriding is not reasonable for PATH
        enum sortFun = "a.key < b.key";
        auto ppair = parent.environment.byPair.array.sort!sortFun;
        auto cpair = environment.byPair.array.sort!sortFun;
        auto env = ppair.merge!sortFun(cpair).assocArray;
        auto leaveDir = parent.leaveTmpdir;
        auto reuse = inheritReuse ? parent.reuseParentTmpdir
                                  : tdir == parent.tmpdir;
        Config c = {
            tag: t, workdir: wdir, tmpdir: tdir,
            environment: env.assumeUnique,
            leaveTmpdir: leaveDir, reuseParentTmpdir: reuse,
        };
        return c;
    }

    unittest
    {
        Config p = { tag: "" };
        Config c = { tag: "child" };
        assert(c.inherits(p).tag == "child");
    }

    unittest
    {
        Config p = { tag: "parent" };
        Config c = { tag: "" };
        assert(c.inherits(p).tag == "parent");
    }

    unittest
    {
        Config p = { tag: "foo" };
        Config c = { tag: "~(tag).bar" };
        assert(c.inherits(p).tag == "foo.bar");
    }

    unittest
    {
        Config p = { tag: "parent" };
        Config c = { tag: "child" };
        assert(c.inherits(p).tag == "parent");
    }

    @system unittest // due to std.conv.to
    {
        import std.conv : to;

        // Specified env vars cannot be overriden by parents
        // TODO: more appropriate behavior
        Config p = { environment: [ "PATH": "/usr/local/bin:/usr/bin", "VAR": "other variable" ] };
        Config c = { environment: [ "PATH": "/custom/path/bin" ] };
        assert(c.inherits(p).environment == [
            "PATH": "/custom/path/bin",
            "VAR": "other variable"
        ].to!(immutable(string[string])));
    }
}

/// ditto
alias Config = immutable Config_;
