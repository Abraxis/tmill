// ~/src/tmill/Treadmill/Views/ProgramEditorView.swift
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
        HSplitView {
            programList
                .frame(minWidth: 200)
            if let program = selectedProgram {
                ProgramDetailView(program: program)
                    .frame(minWidth: 300)
            } else {
                Text("Select or create a program")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var programList: some View {
        VStack {
            List(selection: $selectedProgram) {
                ForEach(programs, id: \.objectID) { program in
                    Text(program.name)
                        .tag(program)
                        .onTapGesture { selectedProgram = program }
                }
                .onDelete(perform: deletePrograms)
            }
            HStack {
                Button(action: addProgram) {
                    Label("New Program", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(8)
        }
    }

    private func addProgram() {
        let program = WorkoutProgram(entity: NSEntityDescription.entity(forEntityName: "WorkoutProgram", in: viewContext)!, insertInto: viewContext)
        program.id = UUID()
        program.name = "New Program"
        program.createdAt = Date()

        // Add one default segment
        let segment = ProgramSegment(entity: NSEntityDescription.entity(forEntityName: "ProgramSegment", in: viewContext)!, insertInto: viewContext)
        segment.id = UUID()
        segment.order = 0
        segment.targetSpeed = 3.0
        segment.targetIncline = 0
        segment.goalType = GoalType.time.rawValue
        segment.goalValue = 300  // 5 minutes
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

struct ProgramDetailView: View {
    @ObservedObject var program: WorkoutProgram
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Program Name", text: Binding(
                get: { program.name },
                set: { program.name = $0; try? viewContext.save() }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3)

            Text("Segments")
                .font(.headline)

            List {
                ForEach(program.sortedSegments, id: \.objectID) { segment in
                    SegmentRow(segment: segment)
                }
                .onMove(perform: moveSegments)
                .onDelete(perform: deleteSegments)
            }

            HStack {
                Button(action: addSegment) {
                    Label("Add Segment", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding()
    }

    private func addSegment() {
        let segment = ProgramSegment(entity: NSEntityDescription.entity(forEntityName: "ProgramSegment", in: viewContext)!, insertInto: viewContext)
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

struct SegmentRow: View {
    @ObservedObject var segment: ProgramSegment
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed:")
                        .foregroundStyle(.secondary)
                    Stepper(
                        String(format: "%.1f km/h", segment.targetSpeed),
                        value: Binding(
                            get: { segment.targetSpeed },
                            set: { segment.targetSpeed = $0; try? viewContext.save() }
                        ),
                        in: FTMSProtocol.speedMin...FTMSProtocol.speedMax,
                        step: FTMSProtocol.speedStep
                    )
                }

                HStack {
                    Text("Incline:")
                        .foregroundStyle(.secondary)
                    Stepper(
                        String(format: "%.0f%%", segment.targetIncline),
                        value: Binding(
                            get: { segment.targetIncline },
                            set: { segment.targetIncline = $0; try? viewContext.save() }
                        ),
                        in: FTMSProtocol.inclineMin...FTMSProtocol.inclineMax,
                        step: FTMSProtocol.inclineStep
                    )
                }

                HStack {
                    Picker("Goal:", selection: Binding(
                        get: { segment.goalType },
                        set: { segment.goalType = $0; try? viewContext.save() }
                    )) {
                        ForEach(GoalType.allCases, id: \.rawValue) { type in
                            Text(type.rawValue.capitalized).tag(type.rawValue)
                        }
                    }
                    .frame(width: 150)

                    TextField("Value", value: Binding(
                        get: { segment.goalValue },
                        set: { segment.goalValue = $0; try? viewContext.save() }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                    Text(goalUnit)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var goalUnit: String {
        switch segment.goalTypeEnum {
        case .distance: return "m"
        case .time: return "sec"
        case .calories: return "cal"
        }
    }
}
