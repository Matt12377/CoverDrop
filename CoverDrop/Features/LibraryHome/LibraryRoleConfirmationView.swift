import SwiftUI

struct LibraryRoleConfirmationView: View {
    let pendingImport: PendingLibraryImport
    let onCancel: () -> Void
    let onConfirm: (LibraryRole) -> Void

    @State private var selectedRole: LibraryRole

    init(
        pendingImport: PendingLibraryImport,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (LibraryRole) -> Void
    ) {
        self.pendingImport = pendingImport
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedRole = State(initialValue: pendingImport.suggestedRole)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("确认文件夹角色")
                .font(.title2.bold())

            Text(pendingImport.url.path)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(pendingImport.explanation)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Picker("这个文件夹是", selection: $selectedRole) {
                ForEach(LibraryRole.allCases, id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("添加") { onConfirm(selectedRole) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
