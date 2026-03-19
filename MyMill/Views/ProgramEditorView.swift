import SwiftUI
import CoreData

struct ProgramEditorView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WorkoutProgram.createdAt, ascending: false)],
        animation: .default
    )
    private var programs: FetchedResults<WorkoutProgram>

    @State private var selectedProgram: WorkoutProgram?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProgram) {
                ForEach(programs, id: \.objectID) { program in
                    ProgramRow(program: program)
                        .tag(program)
                }
                .onDelete(perform: deletePrograms)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addProgram) {
                        Label("New Program", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let program = selectedProgram {
                ProgramDetailView(program: program)
            } else {
                ContentUnavailableView(
                    "No Program Selected",
                    systemImage: "figure.walk",
                    description: Text("Select a program or create a new one.")
                )
            }
        }
        .frame(minWidth: 650, minHeight: 450)
        .navigationTitle("Workout Programs")
    }

    private func addProgram() {
        let program = WorkoutProgram(
            entity: NSEntityDescription.entity(forEntityName: "WorkoutProgram", in: viewContext)!,
            insertInto: viewContext
        )
        program.id = UUID()
        program.name = "New Program"
        program.createdAt = Date()

        let segment = ProgramSegment(
            entity: NSEntityDescription.entity(forEntityName: "ProgramSegment", in: viewContext)!,
            insertInto: viewContext
        )
        segment.id = UUID()
        segment.order = 0
        segment.targetSpeed = 3.0
        segment.targetIncline = 0
        segment.goalType = GoalType.time.rawValue
        segment.goalValue = 300
        segment.program = program
        program.segments = NSOrderedSet(array: [segment])

        try? viewContext.save()
        selectedProgram = program
    }

    private func deletePrograms(at offsets: IndexSet) {
        for index in offsets {
            let program = programs[index]
            if selectedProgram == program { selectedProgram = nil }
            viewContext.delete(program)
        }
        try? viewContext.save()
    }
}

// MARK: - Program Row

private struct ProgramRow: View {
    @ObservedObject var program: WorkoutProgram

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(program.name)
                .font(.headline)
            let segs = program.sortedSegments
            Text("\(segs.count) segment\(segs.count == 1 ? "" : "s") · \(totalDuration(segs))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func totalDuration(_ segments: [ProgramSegment]) -> String {
        let totalSec = segments
            .filter { $0.goalTypeEnum == .time }
            .reduce(0.0) { $0 + $1.goalValue }
        if totalSec > 0 {
            let min = Int(totalSec) / 60
            return "\(min) min"
        }
        return "custom goals"
    }
}

// MARK: - Program Detail

struct ProgramDetailView: View {
    @ObservedObject var program: WorkoutProgram
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Program Name", text: Binding(
                    get: { program.name },
                    set: { program.name = $0; try? viewContext.save() }
                ))
                .textFieldStyle(.plain)
                .font(.title2.bold())

                Spacer()

                Button(action: addSegment) {
                    Label("Add Segment", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            List {
                ForEach(Array(program.sortedSegments.enumerated()), id: \.element.objectID) { index, segment in
                    SegmentCard(segment: segment, index: index + 1)
                }
                .onMove(perform: moveSegments)
                .onDelete(perform: deleteSegments)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func addSegment() {
        let segment = ProgramSegment(
            entity: NSEntityDescription.entity(forEntityName: "ProgramSegment", in: viewContext)!,
            insertInto: viewContext
        )
        segment.id = UUID()
        segment.order = Int16(program.segments.count)
        segment.targetSpeed = 3.0
        segment.targetIncline = 0
        segment.goalType = GoalType.time.rawValue
        segment.goalValue = 300
        segment.program = program

        let mutable = program.segments.mutableCopy() as! NSMutableOrderedSet
        mutable.add(segment)
        program.segments = mutable
        try? viewContext.save()
    }

    private func deleteSegments(at offsets: IndexSet) {
        let mutable = program.segments.mutableCopy() as! NSMutableOrderedSet
        for index in offsets {
            if let segment = mutable.object(at: index) as? ProgramSegment {
                viewContext.delete(segment)
            }
        }
        mutable.removeObjects(at: offsets)
        program.segments = mutable
        reorderSegments()
        try? viewContext.save()
    }

    private func moveSegments(from source: IndexSet, to destination: Int) {
        let mutable = program.segments.mutableCopy() as! NSMutableOrderedSet
        mutable.moveObjects(at: source, to: destination)
        program.segments = mutable
        reorderSegments()
        try? viewContext.save()
    }

    private func reorderSegments() {
        for (i, segment) in program.sortedSegments.enumerated() {
            segment.order = Int16(i)
        }
    }
}

// MARK: - Segment Card

private struct SegmentCard: View {
    @ObservedObject var segment: ProgramSegment
    @Environment(\.managedObjectContext) private var viewContext
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            // Segment number
            Text("\(index)")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                // Speed & Incline row
                HStack(spacing: 16) {
                    // Speed: text input + stepper
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .foregroundStyle(.blue)
                            .frame(width: 16)
                        TextField("", value: Binding(
                            get: { segment.targetSpeed },
                            set: { segment.targetSpeed = clampSpeed($0); try? viewContext.save() }
                        ), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                        Text("km/h")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper("", value: Binding(
                            get: { segment.targetSpeed },
                            set: { segment.targetSpeed = $0; try? viewContext.save() }
                        ), in: FTMSProtocol.speedMin...FTMSProtocol.speedMax, step: FTMSProtocol.speedStep)
                        .labelsHidden()
                    }

                    // Incline: text input + stepper
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.purple)
                            .frame(width: 16)
                        TextField("", value: Binding(
                            get: { segment.targetIncline },
                            set: { segment.targetIncline = clampIncline($0); try? viewContext.save() }
                        ), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 45)
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper("", value: Binding(
                            get: { segment.targetIncline },
                            set: { segment.targetIncline = $0; try? viewContext.save() }
                        ), in: FTMSProtocol.inclineMin...FTMSProtocol.inclineMax, step: FTMSProtocol.inclineStep)
                        .labelsHidden()
                    }
                }

                // Goal row
                HStack(spacing: 8) {
                    Image(systemName: goalIcon)
                        .foregroundStyle(.green)
                        .frame(width: 16)

                    Picker("", selection: Binding(
                        get: { segment.goalType },
                        set: { newType in
                            // Convert value when switching between time and other types
                            if newType == GoalType.time.rawValue && segment.goalType != GoalType.time.rawValue {
                                // Convert to seconds if it looks like it was minutes
                                if segment.goalValue < 120 { segment.goalValue = segment.goalValue * 60 }
                            } else if newType != GoalType.time.rawValue && segment.goalType == GoalType.time.rawValue {
                                // Don't auto-convert
                            }
                            segment.goalType = newType
                            try? viewContext.save()
                        }
                    )) {
                        ForEach(GoalType.allCases, id: \.rawValue) { type in
                            Text(type.rawValue.capitalized).tag(type.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    if segment.goalTypeEnum == .time {
                        // Show minutes input for time goals
                        TextField("", value: Binding(
                            get: { segment.goalValue / 60 },
                            set: { segment.goalValue = $0 * 60; try? viewContext.save() }
                        ), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                        Text("min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("", value: Binding(
                            get: { segment.goalValue },
                            set: { segment.goalValue = $0; try? viewContext.save() }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        Text(goalUnit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(segment.goalDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func clampSpeed(_ v: Double) -> Double {
        max(FTMSProtocol.speedMin, min(FTMSProtocol.speedMax, v))
    }

    private func clampIncline(_ v: Double) -> Double {
        max(FTMSProtocol.inclineMin, min(FTMSProtocol.inclineMax, v))
    }

    private var goalIcon: String {
        switch segment.goalTypeEnum {
        case .time: return "clock"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .calories: return "flame"
        }
    }

    private var goalUnit: String {
        switch segment.goalTypeEnum {
        case .distance: return "m"
        case .time: return "min"
        case .calories: return "cal"
        }
    }
}
