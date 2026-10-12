// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Anki card mining for gw-read: gw-yomi's `anki` (the note, its fields
//! rendered as HTML, the AnkiConnect request and reply) plus gw-read's
//! `Job`, which sends it (`anki_job.zig`).

const anki = @import("gw_yomi").anki;

pub const Source = anki.Source;
pub const FieldMap = anki.FieldMap;
pub const default_fields = anki.default_fields;
pub const default_url = anki.default_url;
pub const default_deck = anki.default_deck;
pub const default_model = anki.default_model;
pub const jpod_audio_url = anki.jpod_audio_url;
pub const jpod_missing_md5 = anki.jpod_missing_md5;
pub const Image = anki.Image;
pub const AudioState = anki.AudioState;
pub const Note = anki.Note;
pub const fieldValue = anki.fieldValue;
pub const previewValue = anki.previewValue;
pub const writeHtml = anki.writeHtml;
pub const furigana = anki.furigana;
pub const audioUrl = anki.audioUrl;
pub const isJpodUrl = anki.isJpodUrl;
pub const Target = anki.Target;
pub const buildAddNote = anki.buildAddNote;
pub const buildAction = anki.buildAction;
pub const Reply = anki.Reply;
pub const parseReply = anki.parseReply;

pub const Job = @import("anki_job.zig").Job;
