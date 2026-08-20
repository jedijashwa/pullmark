# Localizations

One `<locale>.lproj/Localizable.strings` per language, hand-authored
(no Xcode pipeline — see docs/specs/app-i18n.md). English is the key;
there is no en.lproj. `make-app.sh` copies these into the app and the
Quick Look appex at assembly time; `scripts/check-strings.py` keeps
them complete (run by `make test`).

Locales: zh-Hans, ja, fr, de, nl, es, pt-BR.
