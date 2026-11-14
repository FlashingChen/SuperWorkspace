import XCTest
@testable import SuperWorkspace

@MainActor
final class SubtitleReviewTests: XCTestCase {
    private func withStorage(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root)
    }

    private func project(subtitles: [TranscriptSegment], duration: Double = 20,
                         trim: ClosedRange<Double>? = nil) -> VideoProject {
        var project = VideoProject(name: "Review")
        var material = Material()
        material.duration = duration
        material.exportState = .complete
        material.transcriptState = .complete
        material.subtitleLayoutVersion = SubtitleSegmentation.version
        material.subtitles = subtitles
        if let trim { material.trimStart = trim.lowerBound; material.trimEnd = trim.upperBound }
        project.materials = [material]
        return project
    }

    private func material(_ subtitles: [TranscriptSegment]) -> Material {
        var material = Material()
        material.duration = 10
        material.exportState = .complete
        material.transcriptState = .complete
        material.subtitleLayoutVersion = SubtitleSegmentation.version
        material.subtitles = subtitles
        return material
    }

    // MARK: - Local checks

    func testLocalReviewFindsShortOverlapDuplicateAndSpacing() {
        let review = SubtitleReviewer.local(project(subtitles: [
            .init(start: 0.2, end: 0.5, text: "这是一条来不及读的字幕"),
            .init(start: 0.4, end: 1.0, text: "Overlap here"),
            .init(start: 1.0, end: 2.0, text: "重复内容"),
            .init(start: 2.0, end: 3.0, text: "重复内容"),
            .init(start: 3.0, end: 3.5, text: " spaced "),
        ]))
        XCTAssertEqual(review.checkedLines, 5)
        XCTAssertTrue(review.issues.contains { $0.kind == .timing && $0.severity == .warning && $0.index == 0 })
        XCTAssertTrue(review.issues.contains { $0.kind == .timing && $0.severity == .error && $0.index == 1 })
        XCTAssertTrue(review.issues.contains { $0.kind == .segmentation && $0.index == 3 && $0.message.contains("重复") })
        XCTAssertTrue(review.issues.contains { $0.kind == .text && $0.index == 4 && $0.replacement == "spaced" })
    }

    func testLocalReviewNotesCaptionsClippedByTheClipBounds() {
        let review = SubtitleReviewer.local(project(subtitles: [
            .init(start: 1, end: 3, text: "前一句"),
            .init(start: 4, end: 5, text: "中间"),
            .init(start: 9, end: 11, text: "后一句"),
        ], duration: 12, trim: 2...10))
        XCTAssertTrue(review.issues.contains { $0.kind == .boundary && $0.index == 0 && $0.severity == .note })
        XCTAssertTrue(review.issues.contains { $0.kind == .boundary && $0.index == 2 && $0.severity == .note })
        XCTAssertFalse(review.issues.contains { $0.kind == .boundary && $0.index == 1 })
    }

    func testLocalReviewLeavesHealthyCaptionsAlone() {
        let review = SubtitleReviewer.local(project(subtitles: [
            .init(start: 1, end: 3, text: "这是一句正常长度的字幕"),
            .init(start: 3.2, end: 5, text: "第二句"),
        ]))
        XCTAssertTrue(review.issues.isEmpty)
        XCTAssertEqual(review.checkedLines, 2)
    }

    func testLocalReviewSuggestsJoiningALoneFunctionWord() {
        let review = SubtitleReviewer.local(project(subtitles: [
            .init(start: 0.2, end: 1.0, text: "deploy"),
            .init(start: 1.0, end: 1.4, text: "it"),
        ]))
        let issue = review.issues.first { $0.index == 1 && $0.kind == .segmentation }
        XCTAssertEqual(issue?.join, .previous)
    }

    func testLocalReviewLeavesMeaningfulShortCaptionsAlone() {
        let sentenceFinal = SubtitleReviewer.local(project(subtitles: [
            .init(start: 0.2, end: 1.0, text: "deploy."),
            .init(start: 1.0, end: 1.4, text: "it"),
        ]))
        XCTAssertFalse(sentenceFinal.issues.contains { $0.join != nil })

        let name = SubtitleReviewer.local(project(subtitles: [
            .init(start: 0.2, end: 1.0, text: "using"),
            .init(start: 1.0, end: 1.4, text: "AI"),
        ]))
        XCTAssertFalse(name.issues.contains { $0.join != nil })
    }

    func testReviewMergesALoneWordReportedByLocalChecks() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1.0, text: "deploy"),
                                              .init(start: 1.0, end: 1.4, text: "it")])
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let applied = state.applySubtitleReviewFixes(SubtitleReviewer.local(project), projectID: project.id)
            XCTAssertEqual(applied.applied.count, 1)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["deploy it"])
            XCTAssertTrue(applied.issues.isEmpty)
        }
    }

    // MARK: - Text fixes

    func testReplacementKeepsTheFixLocalAndMatchesTheScript() {
        let simplified = SubtitleReviewer.validatedReplacement("我们参加了一个小红树的黑客松",
                                                              "我们参加了一个小红书的黑客松")
        XCTAssertEqual(simplified, "我们参加了一个小红书的黑客松")

        let traditional = SubtitleReviewer.validatedReplacement("我們參加了一個小紅樹的黑客松",
                                                               "我们参加了一个小红书的黑客松")
        XCTAssertEqual(traditional, "我們參加了一個小紅書的黑客松")

        XCTAssertNil(SubtitleReviewer.validatedReplacement("Hello world", "你好世界"))
        XCTAssertNil(SubtitleReviewer.validatedReplacement("短", "这是一个完全不同的长句子"))
        XCTAssertNil(SubtitleReviewer.validatedReplacement("原句", "原句"))
    }

    func testAIResponseOnlyKeepsBatchLinesAndSafeFixes() {
        let material = material([.init(start: 0, end: 1, text: "小红树"),
                                 .init(start: 1, end: 2, text: "Next")])
        let output = """
        {"issues":[
          {"id":0,"kind":"text","severity":"warning","message":"应是「小红书」","replacement":"小红书"},
          {"id":1,"kind":"segmentation","severity":"note","message":"context only"},
          {"id":7,"kind":"text","severity":"error","message":"out of range"},
          {"id":0,"kind":"unknown","severity":"error","message":"bad kind"},
          {"id":0,"kind":"text","severity":"error","message":"同音错字，应为小红书","replacement":"小红书"}
        ]}
        """
        let issues = SubtitleReviewer.validateResponse(output, material: material, indices: [0])
        XCTAssertEqual(issues?.count, 1)
        XCTAssertEqual(issues?.first?.index, 0)
        XCTAssertEqual(issues?.first?.severity, .error)
        XCTAssertEqual(issues?.first?.replacement, "小红书")
        XCTAssertNil(SubtitleReviewer.validateResponse("not json", material: material, indices: [0]))
    }

    func testAIResponseAcceptsStringIDsAndCapitalisedKinds() {
        let material = material([.init(start: 0, end: 1, text: "Check this")])
        let output = "{\"issues\":[{\"id\":\"0\",\"kind\":\"Segmentation\",\"severity\":\"Warning\",\"message\":\"断句需要确认\"}]}"
        let issues = SubtitleReviewer.validateResponse(output, material: material, indices: [0])
        XCTAssertEqual(issues?.count, 1)
        XCTAssertEqual(issues?.first?.kind, .segmentation)
        XCTAssertEqual(issues?.first?.severity, .warning)
    }

    func testAIResponseKeepsTheIssueWhenTheFixIsTooLarge() {
        let material = material([.init(start: 0, end: 1, text: "小红树")])
        let output = """
        ```json
        {"issues":[{"id":0,"kind":"text","severity":"warning","message":"改写","replacement":"This is an entirely different English sentence"}]}
        ```
        """
        let issues = SubtitleReviewer.validateResponse(output, material: material, indices: [0])
        XCTAssertEqual(issues?.count, 1)
        XCTAssertNil(issues?.first?.replacement)

        let empty = SubtitleReviewer.validateResponse("```json\n{\"issues\":[]}\n```", material: material, indices: [0])
        XCTAssertEqual(empty?.count, 0)
    }

    func testAIReviewRunsThroughAConfiguredCLIAndDropsUnknownLines() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1, text: "First"),
                                              .init(start: 1.5, end: 2.5, text: "小红树")])
            try ProjectLayout.save(project)
            let reply = "{\"issues\":[{\"id\":1,\"kind\":\"text\",\"severity\":\"warning\",\"message\":\"同音错字\",\"replacement\":\"小红书\"},{\"id\":9,\"kind\":\"text\",\"severity\":\"error\",\"message\":\"不存在\"}]}"
            let configuration = TranscriptCorrectionConfiguration(launchPath: "/bin/sh",
                arguments: ["-c", "printf '%s' '\(reply)'", "review-fixture"])
            let review = try await SubtitleReviewer.review(project: project,
                                                           directory: ProjectLayout.directory(for: project),
                                                           configuration: configuration)
            XCTAssertTrue(review.aiChecked)
            XCTAssertTrue(review.issues.contains { $0.index == 1 && $0.replacement == "小红书" })
            XCTAssertFalse(review.issues.contains { $0.index == 9 })
        }
    }

    // MARK: - Full rebuild

    func testRebuildValidationAcceptsAReSegmentedTrack() {
        let original: [TranscriptSegment] = [.init(start: 0.2, end: 1.0, text: "deploy"),
                                             .init(start: 1.0, end: 1.4, text: "it")]
        let output = "{\"captions\":[{\"start\":0.2,\"end\":1.4,\"text\":\"deploy it\"}]}"
        XCTAssertEqual(SubtitleReviewer.validateRebuild(output, original: original, sourceDuration: 4),
                       [.init(start: 0.2, end: 1.4, text: "deploy it")])
    }

    func testRebuildValidationRejectsLostSpeechAndTranslation() {
        let original: [TranscriptSegment] = [.init(start: 0.2, end: 1.0, text: "deploy"),
                                             .init(start: 1.0, end: 1.4, text: "it")]
        XCTAssertNil(SubtitleReviewer.validateRebuild(
            "{\"captions\":[{\"start\":0.2,\"end\":1.0,\"text\":\"deploy\"}]}",
            original: original, sourceDuration: 4))
        XCTAssertNil(SubtitleReviewer.validateRebuild(
            "{\"captions\":[{\"start\":0.2,\"end\":1.4,\"text\":\"部署它\"}]}",
            original: original, sourceDuration: 4))
    }

    func testRebuildValidationRejectsCollapsedTiming() {
        let original: [TranscriptSegment] = [.init(start: 0.2, end: 1.0, text: "deploy"),
                                             .init(start: 1.0, end: 1.4, text: "it")]
        let collapsed = "{\"captions\":[{\"start\":0.2,\"end\":0.3,\"text\":\"deploy\"},{\"start\":0.3,\"end\":0.4,\"text\":\"it\"}]}"
        XCTAssertNil(SubtitleReviewer.validateRebuild(collapsed, original: original, sourceDuration: 4))
        let shifted = "{\"captions\":[{\"start\":0.2,\"end\":1.0,\"text\":\"deploy\"},{\"start\":20,\"end\":20.4,\"text\":\"it\"}]}"
        XCTAssertNil(SubtitleReviewer.validateRebuild(shifted, original: original, sourceDuration: 30))
    }

    func testRebuildValidationTrimsOverlaps() throws {
        let original: [TranscriptSegment] = [.init(start: 0.2, end: 1.0, text: "deploy"),
                                             .init(start: 1.0, end: 1.4, text: "it")]
        let output = "{\"captions\":[{\"start\":0.2,\"end\":1.0,\"text\":\"deploy\"},{\"start\":0.9,\"end\":1.4,\"text\":\"it\"}]}"
        let rebuilt = try XCTUnwrap(SubtitleReviewer.validateRebuild(output, original: original, sourceDuration: 4))
        XCTAssertEqual(rebuilt.count, 2)
        XCTAssertLessThanOrEqual(rebuilt[0].end, rebuilt[1].start + 0.001)
        XCTAssertEqual(rebuilt[1].start, 1.001, accuracy: 0.01)
    }

    func testRebuildPipelineAppliesTheFullTrackAndUndoes() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1.0, text: "deploy"),
                                              .init(start: 1.0, end: 1.4, text: "it")], duration: 4)
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let reply = "{\"captions\":[{\"start\":0.2,\"end\":1.4,\"text\":\"deploy it\"}]}"
            let configuration = TranscriptCorrectionConfiguration(launchPath: "/bin/sh",
                arguments: ["-c", "printf '%s' '\(reply)'", "rebuild-fixture"])
            let rebuild = try await SubtitleReviewer.rebuild(project: project,
                                                             directory: ProjectLayout.directory(for: project),
                                                             configuration: configuration)
            XCTAssertEqual(rebuild.tracks.count, 1)
            let review = state.applySubtitleRebuild(rebuild, projectID: project.id)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["deploy it"])
            XCTAssertEqual(review.rebuild?.materials, 1)
            XCTAssertEqual(review.rebuild?.before, 2)
            XCTAssertEqual(review.rebuild?.after, 1)
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["deploy", "it"])
        }
    }

    func testRebuildSkipsARecordingChangedWhileReviewing() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1.0, text: "deploy")], duration: 4)
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let material = project.materials[0]
            let track = material.subtitles
            var rebuild = SubtitleRebuild(review: SubtitleReview(rebuild: RebuildSummary()),
                                          tracks: [material.mediaID: [.init(start: 0.2, end: 1.0, text: "rebuilt")]],
                                          originals: [material.mediaID: track])
            rebuild.review.rebuild = RebuildSummary(materials: 1, before: 1, after: 1)
            state.editSubtitle(projectID: project.id, materialID: material.id, index: 0, text: "edited")
            let review = state.applySubtitleRebuild(rebuild, projectID: project.id)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].text, "edited")
            XCTAssertEqual(review.rebuild?.skipped, 1)
            XCTAssertEqual(review.rebuild?.materials, 0)
        }
    }

    // MARK: - Resolution and persistence

    func testIssuesFollowTheirCaptionAfterOtherEdits() {
        let material = material([.init(start: 0.2, end: 1, text: "First"),
                                 .init(start: 1.5, end: 2.5, text: "Second")])
        let issue = SubtitleReviewIssue(materialID: material.id, index: 1, start: 1.5, text: "Second",
                                        kind: .text, severity: .warning, message: "check", replacement: nil)
        var shifted = material
        XCTAssertEqual(SubtitleEditing.inserting(.init(start: 0, end: 0.1, text: "New"), into: shifted.subtitles)?.count, 3)
        shifted.subtitles.insert(.init(start: 0, end: 0.1, text: "New"), at: 0)
        XCTAssertEqual(issue.resolvedIndex(in: shifted), 2)

        var edited = material
        edited.subtitles[1].text = "Changed"
        XCTAssertNil(issue.resolvedIndex(in: edited))
    }

    func testReviewRoundTripsThroughTheProjectDirectory() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1, text: "First")])
            try ProjectLayout.save(project)
            let issue = SubtitleReviewIssue(materialID: project.materials[0].id, index: 0, start: 0.2,
                                            text: "First", kind: .text, severity: .warning,
                                            message: "检查", replacement: nil)
            let review = SubtitleReview(issues: [issue], checkedLines: 1, aiChecked: true, note: "完成")
            try review.save(for: project)
            XCTAssertEqual(SubtitleReview.load(for: project), review)

            let state = AppState()
            XCTAssertEqual(state.subtitleReviews[project.id]?.issues.count, 1)
            state.clearSubtitleReview(project.id)
            XCTAssertNil(SubtitleReview.load(for: project))
        }
    }

    // MARK: - Editor commands

    func testReviewAutoAppliesSafeFixesInOneUndoStepAndKeepsStructuralNotes() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1, text: "小红树"),
                                              .init(start: 1.5, end: 2.5, text: " spaced ")])
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let materialID = project.materials[0].id
            let issues = [
                SubtitleReviewIssue(materialID: materialID, index: 0, start: 0.2, text: "小红树",
                                    kind: .text, severity: .warning, message: "同音错字",
                                    replacement: "小红书"),
                SubtitleReviewIssue(materialID: materialID, index: 1, start: 1.5, text: " spaced ",
                                    kind: .text, severity: .note, message: "多余空白",
                                    replacement: "spaced"),
                SubtitleReviewIssue(materialID: materialID, index: 0, start: 0.2, text: "小红树",
                                    kind: .timing, severity: .warning, message: "开头偏快",
                                    replacement: nil),
            ]
            let applied = state.applySubtitleReviewFixes(SubtitleReview(issues: issues, checkedLines: 2),
                                                         projectID: project.id)
            XCTAssertEqual(applied.applied.count, 2)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["小红书", "spaced"])
            XCTAssertEqual(applied.issues.map(\.kind), [.timing])
            XCTAssertEqual(applied.issues.first?.text, "小红书")
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["小红树", " spaced "])
        }
    }

    func testReviewAutoApplyReachesSplitSiblingsAndUndoesAsOneStep() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1, text: "First"),
                                              .init(start: 1.5, end: 2.5, text: "Second")], duration: 4)
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let materialID = project.materials[0].id
            XCTAssertNotNil(state.splitMaterial(project.id, materialID, at: 2))
            let issue = SubtitleReviewIssue(materialID: materialID, index: 0, start: 0.2, text: "First",
                                            kind: .text, severity: .warning, message: "拼写",
                                            replacement: "Firsts")
            let applied = state.applySubtitleReviewFixes(SubtitleReview(issues: [issue]), projectID: project.id)
            XCTAssertEqual(applied.applied.count, 1)
            XCTAssertTrue(state.currentProject!.materials.allSatisfy {
                $0.subtitles.map(\.text) == ["Firsts", "Second"]
            })
            state.undo()
            XCTAssertTrue(state.currentProject!.materials.allSatisfy {
                $0.subtitles.map(\.text) == ["First", "Second"]
            })
        }
    }

    func testReviewAutoMergesAJoinSuggestedForALoneWord() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1.0, text: "deploy"),
                                              .init(start: 1.0, end: 1.4, text: "it")])
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let materialID = project.materials[0].id
            let issue = SubtitleReviewIssue(materialID: materialID, index: 1, start: 1.0, text: "it",
                                            kind: .segmentation, severity: .warning,
                                            message: "单独成条，应与前一条合并", join: .previous)
            let applied = state.applySubtitleReviewFixes(SubtitleReview(issues: [issue]), projectID: project.id)
            XCTAssertEqual(applied.applied.count, 1)
            XCTAssertEqual(applied.applied.first?.before, "deploy + it")
            XCTAssertEqual(applied.applied.first?.after, "deploy it")
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["deploy it"])
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].start, 0.2)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].end, 1.4)
            XCTAssertTrue(applied.issues.isEmpty)
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["deploy", "it"])
        }
    }

    func testReviewAutoMergesWithTheNextCaption() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1.0, text: "end of"),
                                              .init(start: 1.0, end: 2.0, text: "sentence")])
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let materialID = project.materials[0].id
            let issue = SubtitleReviewIssue(materialID: materialID, index: 0, start: 0.2, text: "end of",
                                            kind: .segmentation, severity: .warning,
                                            message: "应与后一条合并", join: .next)
            _ = state.applySubtitleReviewFixes(SubtitleReview(issues: [issue]), projectID: project.id)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["end of sentence"])
        }
    }

    func testAIResponseKeepsJoinOnlyForSegmentationAndValidNeighbours() {
        let material = material([.init(start: 0, end: 1, text: "deploy"),
                                 .init(start: 1, end: 2, text: "it")])
        let output = """
        {"issues":[
          {"id":1,"kind":"segmentation","severity":"warning","message":"合并","join":"previous"},
          {"id":0,"kind":"text","severity":"warning","message":"错字","replacement":"deploy","join":"next"},
          {"id":0,"kind":"segmentation","severity":"warning","message":"第一条不能向前合并","join":"previous"}
        ]}
        """
        let issues = SubtitleReviewer.validateResponse(output, material: material, indices: [0, 1])
        XCTAssertEqual(issues?.count, 3)
        XCTAssertEqual(issues?[0].join, .previous)
        XCTAssertNil(issues?[1].join)
        XCTAssertNil(issues?[2].join)
    }

    func testReviewAutoApplySkipsACaptionChangedWhileReviewing() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1, text: "Edited")])
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let issue = SubtitleReviewIssue(materialID: project.materials[0].id, index: 0, start: 0.2,
                                            text: "Original", kind: .text, severity: .warning,
                                            message: "错字", replacement: "Fixed")
            let applied = state.applySubtitleReviewFixes(SubtitleReview(issues: [issue]), projectID: project.id)
            XCTAssertTrue(applied.applied.isEmpty)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].text, "Edited")
        }
    }

    func testReviewReportsFromBeforeJoinSupportAreDiscarded() async throws {
        try await withStorage { _ in
            let project = project(subtitles: [.init(start: 0.2, end: 1, text: "First")])
            try ProjectLayout.save(project)
            let review = SubtitleReview(issues: [], checkedLines: 1)
            let data = try JSONEncoder().encode(review)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "version")
            try JSONSerialization.data(withJSONObject: object).write(to: SubtitleReview.url(for: project))
            XCTAssertNil(SubtitleReview.load(for: project))
            XCTAssertFalse(FileManager.default.fileExists(atPath: SubtitleReview.url(for: project).path))
        }
    }

    func testReviewDecodesReportsWithoutTheAppliedList() throws {
        let review = SubtitleReview(issues: [], checkedLines: 3, aiChecked: true)
        let data = try JSONEncoder().encode(review)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "applied")
        let legacy = try JSONDecoder().decode(SubtitleReview.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.applied.isEmpty)
        XCTAssertEqual(legacy.checkedLines, 3)
        XCTAssertTrue(legacy.aiChecked)
    }

    func testCaptionInsertDeleteMergeAndSplitAreUndoable() async throws {
        try await withStorage { _ in
            var project = project(subtitles: [.init(start: 1, end: 2, text: "Hello world"),
                                              .init(start: 2.5, end: 3.5, text: "Next")], duration: 6)
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let materialID = project.materials[0].id

            XCTAssertEqual(state.insertSubtitle(project.id, materialID, at: 4), 2)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[2].start, 4)
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[2].end, 6)
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.count, 2)

            XCTAssertTrue(state.deleteSubtitle(project.id, materialID, index: 1))
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["Hello world"])
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.count, 2)

            XCTAssertTrue(state.splitSubtitle(project.id, materialID, index: 0, at: 1.5))
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].text, "Hello")
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[1].text, "world")
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].text, "Hello world")

            XCTAssertTrue(state.mergeSubtitle(project.id, materialID, index: 0))
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["Hello world Next"])
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles.map(\.text), ["Hello world", "Next"])
        }
    }

    func testCaptionDeletionReachesSplitSiblings() async throws {
        try await withStorage { _ in
            var project = project(subtitles: [.init(start: 0.2, end: 1, text: "First"),
                                              .init(start: 1.5, end: 2.5, text: "Second")], duration: 4)
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let materialID = project.materials[0].id
            XCTAssertNotNil(state.splitMaterial(project.id, materialID, at: 2))
            XCTAssertTrue(state.deleteSubtitle(project.id, materialID, index: 0))
            let edited = try XCTUnwrap(state.currentProject)
            XCTAssertTrue(edited.materials.allSatisfy { $0.subtitles.map(\.text) == ["Second"] })
            state.undo()
            let restored = try XCTUnwrap(state.currentProject)
            XCTAssertTrue(restored.materials.allSatisfy { $0.subtitles.map(\.text) == ["First", "Second"] })
        }
    }
}
