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
        guard hasImageCatalog,
            let root = try database.rows("SELECT value FROM metadata WHERE key='image_root'").first?.string("value")
        else { return 0 }
        return Int(
            try database.rows(
                """
                SELECT COUNT(*) AS n FROM (SELECT 1 FROM image_files
                WHERE root=? AND available=1 \(query.isEmpty ? "" : "AND instr(lower(name),lower(?))>0")
                GROUP BY scope,family,substr(relative_path,1,length(relative_path)-length(name)))
                """, [.text(root)] + (query.isEmpty ? [] : [.text(query)])
            ).first?.int("n") ?? 0)
    }
    func directoryImageGroups(query: String = "", offset: Int = 0) throws -> [DirectoryImageGroup] {
        guard hasImageCatalog,
            let root = try database.rows("SELECT value FROM metadata WHERE key='image_root'").first?.string("value")
        else { return [] }
        // Select the page first, then fetch its variants and preview payloads in one query.
        // Filtering picks matching groups but still returns all versions of each selected group.
        let rows = try database.rows(
            """
            WITH page AS (
            SELECT scope,family,substr(relative_path,1,length(relative_path)-length(name)) AS folder,MAX(modified_at) AS latest
            FROM image_files WHERE root=? AND available=1 \(query.isEmpty ? "" : "AND instr(lower(name),lower(?))>0")
            GROUP BY scope,family,folder ORDER BY latest DESC,scope,family,folder LIMIT 60 OFFSET ?
            ), variants AS (
                SELECT i.*,g.folder,g.latest,\(hasPreviewCatalog ? "p.payload" : "NULL") AS preview_payload,
                       ROW_NUMBER() OVER (PARTITION BY i.scope,i.family,g.folder ORDER BY i.id) AS variant_index
                FROM page g JOIN image_files i ON i.root=? AND i.scope=g.scope AND i.family=g.family
                    AND i.available=1 AND substr(i.relative_path,1,length(i.relative_path)-length(i.name))=g.folder
                \(hasPreviewCatalog ? "LEFT JOIN image_previews p ON p.file_id=i.id" : "")
            ) SELECT * FROM variants WHERE variant_index<=100 ORDER BY latest DESC,scope,family,folder,id
            """, [.text(root)] + (query.isEmpty ? [] : [.text(query)]) + [.integer(Int64(max(0, offset))), .text(root)])
        var order = [String]()
        var groups = [String: [DirectoryImageItem]]()
        for row in rows {
            let key = digest(
                root + "|" + row.string("scope")! + "|" + row.string("folder")! + "|" + row.string("family")!)
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            let file = DiscoveredFile(
                id: row.string("id")!, root: root, relativePath: row.string("relative_path")!,
                name: row.string("name")!,
                bytes: row.int("bytes")!, modifiedAt: row.string("modified_at")!, available: true)
            groups[key]!.append(
                DirectoryImageItem(file: file, preview: imagePreview(for: file, payload: row.data("preview_payload"))))
        }
        return order.map { key in
            let items = groups[key]!.sorted {
                let a = $0.preview
                let b = $1.preview
                if (a?.state == "ready") != (b?.state == "ready") { return a?.state == "ready" }
                let x = (a?.width ?? 0) * (a?.height ?? 0)
                let y = (b?.width ?? 0) * (b?.height ?? 0)
                if x != y { return x > y }
                return $0.file.bytes == $1.file.bytes ? $0.id < $1.id : $0.file.bytes > $1.file.bytes
            }
            return DirectoryImageGroup(id: key, versions: items)
        }
    }
}
