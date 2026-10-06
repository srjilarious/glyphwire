// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Every key gw-read answers to, by name. A key press (or a typed
//! character: `?`, `:`, `]`) is looked up in the table for the reader's
//! current mode and the result is switched on in `Ui.perform`, so
//! `read.conf.lua` can rebind any of them:
//!
//!     config = { keys = {
//!         page = { ["n"] = "nextPage", ["space"] = false },
//!         card = { ["y"] = "accept" },
//!     } }
//!
//! The modes are the precedence the old if-chain had implied by statement
//! order, written down (`parentScope`): an Anki card in progress takes
//! every key, and the AI panel's confirm / in-flight states take a few
//! before the page does.
//!
//! Not here: the `:` goto prompt's digits and editing keys, and the
//! second `g` of `gg`, which are a text field and a key sequence rather
//! than bindings.
//!
//! The tag names are the config names, so they're camelCase on purpose
//! and renaming one breaks users' configs.

const keybind = @import("applib").keybind;

pub const Action = enum {
    /// Does nothing, and stops the lookup there: `false` in a mode table
    /// binds this, so it can hide a page binding rather than fall through.
    none,

    // ── page ─────────────────────────────────────────────────────────

    /// Closes the help overlay, else quits.
    quit,
    /// Closes the help overlay, else the OCR dialog, else quits.
    back,
    toggleHelp,
    /// The `:` page-number prompt.
    gotoPage,
    /// The first key of `gg` (the first page).
    goPrefix,
    nextPage,
    prevPage,
    /// The side panel's next page while it has more to show, else the
    /// book's next page.
    pageDown,
    pageUp,
    firstPage,
    lastPage,
    /// `jump_pages` pages on, or the next lookup hit while the panel
    /// lists more than one.
    jumpForward,
    jumpBack,
    panLeft,
    panRight,
    panUp,
    panDown,
    /// Pan along the axis if the page overflows it, else turn the page
    /// that way (resolved against the reading direction).
    panOrTurnLeft,
    panOrTurnRight,
    panOrPageUp,
    panOrPageDown,
    fitScreen,
    fitWidth,
    fitHeight,
    naturalSize,
    zoomIn,
    zoomOut,
    flipDirection,
    /// OCR: the next / previous text block's dialog.
    nextBlock,
    prevBlock,
    toggleHints,
    cycleLayout,
    /// Hold to fade the dialog (acts on press and release).
    peek,
    toggleDialogHidden,
    cycleDictScale,
    cycleOcrScale,
    startCard,
    startAi,

    // ── card / AI panel ──────────────────────────────────────────────

    /// Enter in a dialog: accept the crop, send the card, confirm the AI
    /// request, retry a failed send.
    accept,
    /// Escape in a dialog: skip the image, discard the card, cancel the
    /// request.
    cancel,
    /// Back to cropping from the card preview.
    recrop,
    nudgeLeft,
    nudgeRight,
    nudgeUp,
    nudgeDown,
    cropGrow,
    cropShrink,
    scrollPanelDown,
    scrollPanelUp,
};

pub const Default = keybind.Default(Action);

/// `page` is the reader itself; `card` is an Anki card in progress (crop,
/// preview, sending); `confirm` is the AI panel asking before its first
/// send; `busy` is an AI request in flight.
pub const Scope = enum { page, card, confirm, busy };

/// A card takes every key: a page turn under it would pull the page out
/// from beneath the crop. The AI states take what they bind and pass the
/// rest to the page.
fn parentScope(scope: Scope) ?Scope {
    return switch (scope) {
        .page, .card => null,
        .confirm, .busy => .page,
    };
}

pub const Keymaps = keybind.Scoped(Scope, Action, parentScope, .none);
pub const Override = keybind.ScopedOverride(Scope, Action);

pub const page_defaults = [_]Default{
    .{ .chord = "q", .action = .quit },
    .{ .chord = "escape", .action = .back },
    .{ .chord = "?", .action = .toggleHelp },
    .{ .chord = ":", .action = .gotoPage },
    .{ .chord = "g", .action = .goPrefix },
    .{ .chord = "shift+g", .action = .lastPage },
    .{ .chord = "space", .action = .nextPage },
    .{ .chord = "backspace", .action = .prevPage },
    .{ .chord = "page_down", .action = .pageDown },
    .{ .chord = "page_up", .action = .pageUp },
    .{ .chord = "home", .action = .firstPage },
    .{ .chord = "end", .action = .lastPage },
    .{ .chord = "]", .action = .jumpForward },
    .{ .chord = "[", .action = .jumpBack },
    .{ .chord = "h", .action = .panLeft },
    .{ .chord = "l", .action = .panRight },
    .{ .chord = "k", .action = .panUp },
    .{ .chord = "j", .action = .panDown },
    .{ .chord = "left", .action = .panOrTurnLeft },
    .{ .chord = "right", .action = .panOrTurnRight },
    .{ .chord = "up", .action = .panOrPageUp },
    .{ .chord = "down", .action = .panOrPageDown },
    .{ .chord = "f", .action = .fitScreen },
    .{ .chord = "w", .action = .fitWidth },
    .{ .chord = "t", .action = .fitHeight },
    .{ .chord = "1", .action = .naturalSize },
    // `=` as well as `+`: the unshifted key is just as good a "zoom in"
    // and saves the reach.
    .{ .chord = "+", .action = .zoomIn },
    .{ .chord = "=", .action = .zoomIn },
    .{ .chord = "-", .action = .zoomOut },
    .{ .chord = "d", .action = .flipDirection },
    .{ .chord = "tab", .action = .nextBlock },
    .{ .chord = "shift+tab", .action = .prevBlock },
    .{ .chord = "o", .action = .toggleHints },
    .{ .chord = "v", .action = .cycleLayout },
    .{ .chord = "z", .action = .peek },
    .{ .chord = "\\", .action = .toggleDialogHidden },
    .{ .chord = "s", .action = .cycleDictScale },
    .{ .chord = "shift+s", .action = .cycleOcrScale },
    .{ .chord = "c", .action = .startCard },
    .{ .chord = "a", .action = .startAi },
};

pub const card_defaults = [_]Default{
    .{ .chord = "enter", .action = .accept },
    .{ .chord = "kp_enter", .action = .accept },
    .{ .chord = "escape", .action = .cancel },
    .{ .chord = "r", .action = .recrop },
    .{ .chord = "left", .action = .nudgeLeft },
    .{ .chord = "h", .action = .nudgeLeft },
    .{ .chord = "right", .action = .nudgeRight },
    .{ .chord = "l", .action = .nudgeRight },
    .{ .chord = "up", .action = .nudgeUp },
    .{ .chord = "k", .action = .nudgeUp },
    .{ .chord = "down", .action = .nudgeDown },
    .{ .chord = "j", .action = .nudgeDown },
    .{ .chord = "+", .action = .cropGrow },
    .{ .chord = "=", .action = .cropGrow },
    .{ .chord = "-", .action = .cropShrink },
    .{ .chord = "page_down", .action = .scrollPanelDown },
    .{ .chord = "page_up", .action = .scrollPanelUp },
};

pub const confirm_defaults = [_]Default{
    .{ .chord = "enter", .action = .accept },
    .{ .chord = "kp_enter", .action = .accept },
    // `a` again sends, the key that asked.
    .{ .chord = "a", .action = .accept },
    .{ .chord = "escape", .action = .cancel },
};

pub const busy_defaults = [_]Default{
    .{ .chord = "escape", .action = .cancel },
};

pub const defaults: Keymaps.Defaults = .init(.{
    .page = &page_defaults,
    .card = &card_defaults,
    .confirm = &confirm_defaults,
    .busy = &busy_defaults,
});
