import Foundation

func readBoundedData(_ url:URL,maxBytes:Int=20_000_000) throws -> Data {
    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
    guard values.isRegularFile == true else{throw NSError(domain:"Lumio",code:2,userInfo:[NSLocalizedDescriptionKey:"The selected file is not a regular file."])}
    guard let size=values.fileSize,size<=maxBytes else{throw NSError(domain:"Lumio",code:3,userInfo:[NSLocalizedDescriptionKey:"The selected project or recording data is too large."])}
    return try Data(contentsOf:url,options:.mappedIfSafe)
}
