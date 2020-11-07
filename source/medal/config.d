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
}

/// ditto
alias Config = immutable Config_;
