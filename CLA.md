<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# glyphwire Contributor Licence Agreement

**Version 1.0**

> **This document has not been reviewed by a lawyer.** It is modelled on
> well-established templates (the Apache Individual CLA, and the
> assignment-with-fallback pattern used by several commercial open-source
> projects). If glyphwire ever becomes something you would go to court
> over, have a solicitor review this before relying on it.

By contributing to glyphwire you agree to the terms below. You do not need
to send anything separately: the act of signing off a contribution (see
[How to sign](#how-to-sign)) is your agreement.

## Why this exists

glyphwire is published under three licences today ([`LICENSE.md`](LICENSE.md)),
and its maintainer may need to change them: to relicense a component, to
dual-licence, to grant an exception to an embedder, or to move the project
somewhere it can be sustained.

That is only possible if one person can speak for the whole codebase. Once
a contribution lands under a copyleft licence and its author keeps the
copyright, nobody can relicense it without tracking that author down. This
agreement keeps the project relicensable by a single decision.

In return, section 4 gives you your own work back under a permissive
licence, so signing this never costs you the ability to reuse what you
wrote.

## 1. Definitions

**"You"** means the individual or legal entity agreeing to these terms.

**"Maintainer"** means Jeff DeWall, and any person or entity to whom the
copyright in the glyphwire project is subsequently transferred.

**"Project"** means glyphwire, in any of its repositories.

**"Contribution"** means any original work of authorship — code,
documentation, configuration, assets, tests, or anything else — that You
intentionally submit to the Project. Submission includes any form of
electronic, written or verbal communication sent to the Maintainer or the
Project, including pull requests, patches, issue comments and email, but
excludes anything conspicuously marked **"Not a Contribution."**

## 2. Assignment of copyright

You assign to the Maintainer all right, title and interest in the copyright
in Your Contribution, worldwide and for the full term of copyright,
including all renewals and extensions.

## 3. Fallback licence

Some jurisdictions do not permit an author to assign copyright outright. To
the extent that section 2 is ineffective, unenforceable, or limited in Your
jurisdiction, You instead grant the Maintainer a **perpetual, worldwide,
irrevocable, royalty-free, transferable, sub-licensable, exclusive**
licence to use, reproduce, modify, prepare derivative works of, publicly
display, publicly perform, distribute and otherwise exploit Your
Contribution, in whole or in part, **under any licence terms whatsoever,
including proprietary terms**, and to relicense it freely.

This section applies automatically and needs no further action from either
party.

To the fullest extent permitted by applicable law, You waive, and agree not
to assert, any moral rights You hold in Your Contribution against the
Maintainer or anyone receiving the Project from the Maintainer.

## 4. Licence back to You

The Maintainer grants You a perpetual, worldwide, non-exclusive,
royalty-free, irrevocable licence to use Your own Contribution under the
terms of the **Apache License 2.0**, in addition to any rights You have
under the Project's own licences.

You keep the right to use, publish and relicense Your own work elsewhere.
This agreement takes nothing away from You; it adds a right for the
Maintainer.

## 5. Patents

You grant the Maintainer and every recipient of the Project a perpetual,
worldwide, non-exclusive, royalty-free, irrevocable patent licence to make,
have made, use, offer to sell, sell, import and otherwise transfer Your
Contribution, covering only those patent claims You own or control that are
necessarily infringed by Your Contribution alone or by its combination with
the Project.

If You institute patent litigation alleging that the Project or a
Contribution within it constitutes patent infringement, the patent licences
granted to You under this agreement terminate as of the date such
litigation is filed.

## 6. Your representations

You represent that:

1. Each Contribution is Your original work, or You otherwise have the legal
   right to submit it under these terms.
2. If Your employer has rights in work You create, You have received
   permission to make the Contribution on their behalf, or Your employer
   has waived those rights, or Your employer has agreed to these terms.
3. Your Contribution does not knowingly infringe anyone's copyright, patent,
   trademark or trade-secret rights.
4. Any part of Your Contribution that is **not** Your original work is
   clearly identified in the submission, along with its source and licence.
5. You are legally entitled to grant the above, and — if agreeing as an
   entity — the person agreeing is authorised to bind it.

You are not expected to provide support for Your Contribution, and unless
required by law or agreed in writing, You provide it **"AS IS", WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND**, express or implied, including any
warranty of merchantability, fitness for a particular purpose, title or
non-infringement.

## 7. No obligation

The Maintainer is under no obligation to accept, merge, use, or continue to
distribute any Contribution, and may remove or replace it at any time.

## 8. Third-party material

If You wish to submit work that is not Your original creation, submit it
separately from any Contribution, clearly marked **"Submitted on behalf of
a third party: [name]"** and accompanied by its licence and any other
restrictions You are aware of.

## 9. Changed circumstances

You agree to notify the Maintainer if any representation in section 6
becomes inaccurate for a Contribution You have already submitted.

## 10. General

This agreement is governed by the laws of **[JURISDICTION — to be filled in
by the Maintainer]**, without regard to its conflict-of-law provisions.

If any provision is held unenforceable, the remainder stays in force, and
the unenforceable provision is to be read as narrowly as necessary to make
it enforceable while preserving its intent.

This is the entire agreement between You and the Maintainer concerning
Contributions, and supersedes any prior understanding on the subject.

## How to sign

There is no form to fill in and nothing to email.

**On your first contribution,** add yourself to
[`CONTRIBUTORS.md`](CONTRIBUTORS.md) as part of the same pull request:

```
- Ada Lovelace <ada@example.com> — agreed to CLA v1.0
```

That commit, authored by you and recorded permanently in the project's git
history, is your signature.

**On every commit,** include a sign-off trailer:

```
Glyphwire-CLA: 1.0 signed-off-by Ada Lovelace <ada@example.com>
```

Git can add it for you:

```sh
git commit --trailer "Glyphwire-CLA=1.0 signed-off-by Ada Lovelace <ada@example.com>"
```

Or set up an alias once, in your clone, that fills in your own name:

```sh
git config --local alias.cc '!git commit --trailer \
  "Glyphwire-CLA=1.0 signed-off-by $(git config user.name) <$(git config user.email)>"'
```

then use `git cc -m "Added a thing"` in place of `git commit`.

By adding either, you certify that you have read this agreement and agree
to it for that contribution.

## If you cannot sign

Some employers will not permit their staff to assign copyright. If that is
you, open an issue and say so before writing code. A bug report, a
reproduction case, a design review or a documentation correction is a real
contribution and needs no agreement at all.
