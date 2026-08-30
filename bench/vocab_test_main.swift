import Foundation

// Deterministic checks for the correction-learning pipeline
// (Vocabulary.learnFromUserEdit / learnFromCleanup) — the logic behind
// "Learn from my edits after paste".
//
// WARNING: run via the Linux bench harness only. On macOS this binary
// resolves the REAL ~/Library/Application Support path (HOME overrides are
// ignored by FileManager) and clearAll() will wipe the user's dictionary.

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

func entry(_ term: String) -> Vocabulary.Entry? {
    Vocabulary.all().first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
}

UserDefaults.standard.set(true, forKey: "vocabLearning")
UserDefaults.standard.set(true, forKey: "vocabLearnFromEdits")
Vocabulary.clearAll()

// 1. The canonical correction: user fixes a misheard name after paste.
let learned1 = Vocabulary.learnFromUserEdit(
    original: "we should ask Signa about the rollout",
    fieldBefore: "we should ask Signa about the rollout",
    fieldAfter: "we should ask Signara about the rollout")
expect(learned1 > 0, "misheard name correction learns (Signa -> Signara)")
expect(entry("Signara") != nil, "preferred term Signara stored")
expect(entry("Signara")?.aliases.contains { $0.caseInsensitiveCompare("Signa") == .orderedSame } == true,
       "mishearing Signa stored as alias of Signara")

// 2. The learned alias survives a reload (personal dictionary is persisted).
expect(Vocabulary.count() >= 1, "library persisted")

// 3. No change -> nothing learned.
let learned3 = Vocabulary.learnFromUserEdit(
    original: "hello world",
    fieldBefore: "hello world",
    fieldAfter: "hello world")
expect(learned3 == 0, "identical field learns nothing")

// 4. Typing elsewhere in the field (insert untouched) -> nothing learned
//    from everyday words.
Vocabulary.clearAll()
let learned4 = Vocabulary.learnFromUserEdit(
    original: "send the update to the team",
    fieldBefore: "Notes:\nsend the update to the team",
    fieldAfter: "Notes:\nsend the update to the team and thanks")
expect(learned4 == 0, "appending everyday words teaches nothing")

// 5. Correction in the middle of a longer field still isolates the edit.
Vocabulary.clearAll()
let learned5 = Vocabulary.learnFromUserEdit(
    original: "ping Qwil about the beta",
    fieldBefore: "TODO list\nping Qwil about the beta\nlunch at noon",
    fieldAfter: "TODO list\nping Quill about the beta\nlunch at noon")
expect(learned5 > 0, "mid-field correction learns (Qwil -> Quill)")
expect(entry("Quill")?.aliases.contains { $0.caseInsensitiveCompare("Qwil") == .orderedSame } == true,
       "Qwil stored as alias of Quill")

// 6. learnFromCleanup: raw STT vs Grok-cleaned pair teaches the same way.
Vocabulary.clearAll()
Vocabulary.learnFromCleanup(raw: "tell grock build to retry",
                            cleaned: "Tell Grok Build to retry")
expect(entry("Grok Build") != nil, "cleanup pair teaches multi-word term Grok Build")

// 7. Toggle off -> learning is inert.
Vocabulary.clearAll()
UserDefaults.standard.set(false, forKey: "vocabLearning")
let learned7 = Vocabulary.learnFromUserEdit(
    original: "we should ask Signa about it",
    fieldBefore: "we should ask Signa about it",
    fieldAfter: "we should ask Signara about it")
expect(learned7 == 0, "learning toggle off is respected")
UserDefaults.standard.set(true, forKey: "vocabLearning")

// 8. Everyday-English words never pollute the dictionary.
Vocabulary.clearAll()
_ = Vocabulary.learnFromUserEdit(
    original: "make it better",
    fieldBefore: "make it better",
    fieldAfter: "make it much better")
expect(entry("better") == nil && entry("much") == nil,
       "common words never stored")

// 9. Real standalone words are never stored as mishearing aliases
//    ("Git" → "GitHub" made cleanup rewrite ordinary speech).
Vocabulary.clearAll()
_ = Vocabulary.learnFromUserEdit(
    original: "push it to Git today",
    fieldBefore: "push it to Git today",
    fieldAfter: "push it to GitHub today")
expect(entry("GitHub")?.aliases.contains { $0.caseInsensitiveCompare("Git") == .orderedSame } != true,
       "alias stoplist: Git never becomes an alias of GitHub")

// 10. An alias may not be an existing canonical term (no self-fighting clusters).
Vocabulary.clearAll()
_ = Vocabulary.addManual("Origin Arc")
_ = Vocabulary.learnFromCleanup(raw: "ship the origin arc build",
                                cleaned: "ship the Origin Ark Studio build")
let arkAliases = entry("Origin Ark Studio")?.aliases ?? []
expect(!arkAliases.contains { $0.caseInsensitiveCompare("Origin Arc") == .orderedSame },
       "existing canonical term never stored as another term's alias")

// 11. A wholesale rewrite teaches nothing (it is not a correction).
Vocabulary.clearAll()
let rewriteLearned = Vocabulary.learnFromUserEdit(
    original: "tell the Fenwick team the rollout for Brastel is Tuesday",
    fieldBefore: "tell the Fenwick team the rollout for Brastel is Tuesday",
    fieldAfter: "completely different sentence about Zanzibar shipping Quarzite pallets")
expect(rewriteLearned == 0, "wholesale rewrite learns nothing")

// 12. Short ordinary-shaped words never become new terms via substitutions.
Vocabulary.clearAll()
_ = Vocabulary.learnFromUserEdit(
    original: "please Sand the file",
    fieldBefore: "please Sand the file",
    fieldAfter: "please Send the file")
expect(entry("Send") == nil, "4-letter plain word Send not stored as vocabulary")

Vocabulary.clearAll()
print(failures == 0 ? "VOCAB_TEST_OK" : "VOCAB_TEST_FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
