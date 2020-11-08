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
    Config inherits(Config parent) inout pure
    {
        import std.algorithm : either;
        import std.array : replace;
        
        auto t = either(tag.replace("~(tag)", parent.tag), parent.tag);
        auto wdir = either(workdir.replace("~(workdir)", parent.workdir),
                           parent.workdir);
        auto tdir = either(tmpdir.replace("~(tmpdir)", parent.tmpdir),
                           parent.tmpdir);
        Config c = { tag: t, workdir: wdir, tmpdir: tdir };
        return c;
    }
}

/// ditto
alias Config = immutable Config_;
