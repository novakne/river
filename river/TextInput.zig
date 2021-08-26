// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const TextInput = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Server = @import("Server.zig");

const log = std.log.scoped(.text_input);

/// The Relay structure manages the communication between text_input
/// and input_method on a given seat.
pub const Relay = struct {
    seat: *Seat,

    /// List of all TextInput bound to the relay.
    /// Multiple wlr_text_input interfaces can be bound to a relay,
    /// but only one at a time can receive events.
    text_inputs: std.TailQueue(TextInput) = .{},

    input_method: ?*wlr.InputMethodV2 = null,

    new_text_input: wl.Listener(*wlr.TextInputV3) =
        wl.Listener(*wlr.TextInputV3).init(handleNewTextInput),

    // InputMethod
    new_input_method: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleNewInputMethod),
    input_method_commit: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleInputMethodCommit),
    grab_keyboard: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
        wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboard),
    input_method_destroy: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleInputMethodDestroy),
    grab_keyboard_destroy: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
        wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboardDestroy),

    pub fn init(self: *Relay, seat: *Seat) !void {
        self.* = .{
            .seat = seat,
        };

        server.input_method_manager.events.input_method.add(&self.new_input_method);
        server.text_input_manager.events.text_input.add(&self.new_text_input);
    }

    pub fn deinit(self: *Relay) void {
        self.new_input_method.link.remove();
        self.new_text_input.link.remove();
    }

    fn handleNewTextInput(
        listener: *wl.Listener(*wlr.TextInputV3),
        wlr_text_input: *wlr.TextInputV3,
    ) void {
        const self = @fieldParentPtr(Relay, "new_text_input", listener);
        // if (self.seat.wlr_seat != wlr_text_input.seat) return;

        const node = util.gpa.create(std.TailQueue(TextInput).Node) catch return;
        errdefer util.gpa.destroy(node);
        node.data.init(self, wlr_text_input);
        self.text_inputs.append(node);
    }

    // FIXME: segfault
    fn handleNewInputMethod(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const self = @fieldParentPtr(Relay, "new_input_method", listener);
        // if (self.seat.wlr_seat != input_method.seat) return;

        // Only one wlr_input_method can be bound to a seat.
        if (self.input_method != null) {
            log.debug("attempted to connect second input method to a seat", .{});
            input_method.sendUnavailable();
            return;
        }

        self.input_method = input_method;

        if (self.input_method) |im| {
            im.events.commit.add(&self.input_method_commit);
            im.events.grab_keyboard.add(&self.grab_keyboard);
            im.events.destroy.add(&self.input_method_destroy);
            im.keyboard_grab.events.destroy.add(&self.grab_keyboard_destroy);
        }

        const text_input = self.getFocusedTextInput();
        if (text_input) |text| {
            if (text.wlr_text_input.?.focused_surface) |surface| {
                text.wlr_text_input.?.sendEnter(surface);
            }
        }
    }

    fn handleInputMethodCommit(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const self = @fieldParentPtr(Relay, "input_method_commit", listener);
        const text_input = self.getFocusedTextInput();
        if (text_input == null) return;

        assert(input_method == self.input_method);

        if (mem.span(input_method.current.preedit.text).len != 0) {
            if (text_input) |text| {
                text.wlr_text_input.?.sendPreeditString(
                    input_method.current.preedit.text,
                    @intCast(u32, input_method.current.preedit.cursor_begin),
                    @intCast(u32, input_method.current.preedit.cursor_end),
                );
            }
        }

        if (mem.span(input_method.current.commit_text).len != 0) {
            if (text_input) |text| {
                text.wlr_text_input.?.sendCommitString(input_method.current.commit_text);
            }
        }

        if (input_method.current.delete.before_length != 0 or
            input_method.current.delete.after_length != 0)
        {
            if (text_input) |text| {
                text.wlr_text_input.?.sendDeleteSurroundingText(
                    input_method.current.delete.before_length,
                    input_method.current.delete.after_length,
                );
            }
        }

        if (text_input) |text| text.wlr_text_input.?.sendDone();
    }

    fn handleInputMethodGrabKeyboard(
        listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
        keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
    ) void {
        const self = @fieldParentPtr(Relay, "grab_keyboard", listener);

        const active_keyboard = self.seat.wlr_seat.getKeyboard();
        if (active_keyboard) |keyboard| {
            keyboard_grab.setKeyboard(keyboard);
            keyboard_grab.sendModifiers(&keyboard.modifiers);
        }

        keyboard_grab.events.destroy.add(&self.grab_keyboard_destroy);
    }

    fn handleInputMethodDestroy(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const self = @fieldParentPtr(Relay, "input_method_destroy", listener);
        assert(input_method == self.input_method);

        self.input_method = null;

        const text_input = self.getFocusedTextInput();
        if (text_input) |text| text.wlr_text_input.?.sendLeave();
    }

    fn handleInputMethodGrabKeyboardDestroy(
        listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
        input_method: *wlr.InputMethodV2.KeyboardGrab,
    ) void {
        const self = @fieldParentPtr(Relay, "grab_keyboard_destroy", listener);
        self.grab_keyboard_destroy.link.remove();

        if (input_method.keyboard) |keyboard| {
            input_method.input_method.seat.keyboardNotifyModifiers(&keyboard.modifiers);
        }
    }

    pub fn getFocusedTextInput(self: *Relay) ?*TextInput {
        var it = self.text_inputs.first;
        while (it) |input| : (it.next()) return &input.data;
        return null;
    }

    pub fn disableTextInput(self: *Relay, text_input: *TextInput) void {
        self.input_method.?.sendDeactivate();
        self.sendInputMethodState(text_input.wlr_text_input.?);
    }

    pub fn sendInputMethodState(self: *Relay, wlr_text_input: *wlr.TextInputV3) void {
        if (wlr_text_input.active_features == 0) {
            if (wlr_text_input.current.surrounding.text) |text| {
                self.input_method.?.sendSurroundingText(
                    text,
                    wlr_text_input.current.surrounding.cursor,
                    wlr_text_input.current.surrounding.anchor,
                );
            }
        }

        self.input_method.?.sendTextChangeCause(wlr_text_input.current.text_change_cause);

        if (wlr_text_input.active_features == 1) {
            self.input_method.?.sendContentType(
                wlr_text_input.current.content_type.hint,
                wlr_text_input.current.content_type.purpose,
            );
        }

        self.input_method.?.sendDone();
    }
};

relay: *Relay,
wlr_text_input: ?*wlr.TextInputV3,

enable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleEnable),
commit: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleCommit),
disable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDisable),
destroy: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDestroy),

pub fn init(self: *TextInput, relay: *Relay, wlr_text_input: *wlr.TextInputV3) void {
    self.* = .{
        .relay = relay,
        .wlr_text_input = wlr_text_input,
    };

    wlr_text_input.events.enable.add(&self.enable);
    wlr_text_input.events.commit.add(&self.commit);
    wlr_text_input.events.disable.add(&self.disable);
    wlr_text_input.events.destroy.add(&self.destroy);
}

fn handleEnable(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "enable", listener);
    self.relay.input_method.?.sendActivate();
    self.relay.sendInputMethodState(wlr_text_input);
}

fn handleCommit(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "commit", listener);
    self.relay.sendInputMethodState(wlr_text_input);
}

fn handleDisable(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "disable", listener);
    self.relay.disableTextInput(self);
}

fn handleDestroy(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "destroy", listener);

    if (self.wlr_text_input) |text| {
        if (text.current_enabled) self.relay.disableTextInput(self);
    }

    self.enable.link.remove();
    self.commit.link.remove();
    self.disable.link.remove();
    self.destroy.link.remove();

    const node = @fieldParentPtr(std.TailQueue(TextInput).Node, "data", self);
    self.relay.text_inputs.remove(node);
}
