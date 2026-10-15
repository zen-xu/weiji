import Foundation

struct DirectoryImageItem: Identifiable {
    let file: DiscoveredFile
    let preview: ImagePreview?
    var id: String { file.id }
}
struct DirectoryImageGroup: Identifiable {
    let id: String
    let versions: [DirectoryImageItem]
    var preferred: DirectoryImageItem { versions[0] }
}

extension Archive {
    func directoryImageGroupCount(query: String = "") throws -> Int {
        guard hasImageCatalog, let root = try database.rows("SELECT value FROM metadata WHERE key='image_root'").first?.string("value") else { return 0 }
        return Int(try database.rows("""
            SELECT COUNT(*) AS n FROM (SELECT 1 FROM image_files
            WHERE root=? AND available=1 AND instr(lower(name),lower(?))>0
            GROUP BY scope,family,substr(relative_path,1,length(relative_path)-length(name)))
            """, [.text(root), .text(query)]).first?.int("n") ?? 0)
    }
    func directoryImageGroups(query: String = "", offset: Int = 0) throws -> [DirectoryImageGroup] {
        guard hasImageCatalog, let root = try database.rows("SELECT value FROM metadata WHERE key='image_root'").first?.string("value") else { return [] }
        let groups = try database.rows("""
            SELECT scope,family,substr(relative_path,1,length(relative_path)-length(name)) AS folder,MAX(modified_at) AS latest
            FROM image_files WHERE root=? AND available=1 AND instr(lower(name),lower(?))>0
            GROUP BY scope,family,folder ORDER BY latest DESC,scope,family LIMIT 60 OFFSET ?
            """, [.text(root), .text(query), .integer(Int64(max(0, offset)))])
        return try groups.compactMap { row in
            let scope = row.string("scope")!, family = row.string("family")!, folder = row.string("folder")!
            let items = try database.rows("""
                SELECT * FROM image_files WHERE root=? AND scope=? AND family=? AND available=1
                AND substr(relative_path,1,length(relative_path)-length(name))=? LIMIT 100
                """, [.text(root), .text(scope), .text(family), .text(folder)]).map { row in
                    let file = DiscoveredFile(id: row.string("id")!, root: root, relativePath: row.string("relative_path")!, name: row.string("name")!,
                        bytes: row.int("bytes")!, modifiedAt: row.string("modified_at")!, available: true)
                    return DirectoryImageItem(file: file, preview: try imagePreview(for: file))
                }.sorted {
                    let a = $0.preview, b = $1.preview
                    if (a?.state == "ready") != (b?.state == "ready") { return a?.state == "ready" }
                    let x = (a?.width ?? 0) * (a?.height ?? 0), y = (b?.width ?? 0) * (b?.height ?? 0)
                    if x != y { return x > y }
                    return $0.file.bytes == $1.file.bytes ? $0.id < $1.id : $0.file.bytes > $1.file.bytes
                }
            guard !items.isEmpty else { return nil }
            return DirectoryImageGroup(id: digest(root + "|" + scope + "|" + folder + "|" + family), versions: items)
        }
    }
}
