// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! AI translation lookup for a whole OCR bubble: gw-yomi's `ai` (the
//! prompt, each provider's request and reply) plus gw-read's `Job`, which
//! does the round trip (`ai_job.zig`).

const ai = @import("gw_yomi").ai;

pub const Provider = ai.Provider;
pub const anthropicFallbacks = ai.anthropicFallbacks;
pub const anthropic_fallback_beta = ai.anthropic_fallback_beta;
pub const Header = ai.Header;
pub const requestHeaders = ai.requestHeaders;
pub const default_style = ai.default_style;
pub const app_rules = ai.app_rules;
pub const PromptInput = ai.PromptInput;
pub const bookTitle = ai.bookTitle;
pub const Prompt = ai.Prompt;
pub const buildPrompt = ai.buildPrompt;
pub const buildBody = ai.buildBody;
pub const Answer = ai.Answer;
pub const parseAnswer = ai.parseAnswer;
pub const plainText = ai.plainText;
pub const claudeArgv = ai.claudeArgv;

pub const Job = @import("ai_job.zig").Job;
