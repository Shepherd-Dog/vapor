import libc
import HTTP
import Bits
import Core
import Foundation

/// Services files from the public folder.
public final class FileMiddleware: Middleware {
    /// The public directory.
    /// note: does _not_ end with a slash
    let publicDirectory: String
    
    public var webTypes = [MediaType]()

    /// Creates a new filemiddleware.
    public init(publicDirectory: String) {
        self.publicDirectory = publicDirectory.finished(with: "/")
    }

    /// See Middleware.respond.
    public func respond(to req: Request, chainingTo next: Responder) throws -> Future<Response> {
        return try next.respond(to: req).map { response in
            if response.http.status == 404 {
                var path = req.http.uri.path
                if path.hasPrefix("/") {
                    path = String(path.dropFirst())
                }
                guard !path.contains("../") else {
                    throw Abort(.forbidden)
                }
                
                let filePath = self.publicDirectory + path
                
                let response = req.makeResponse()
                response.http.status = .ok
                
                var stat = libc.stat()
                
                let fileFD = open(filePath, O_RDONLY | O_ASYNC)
                
                guard fileFD >= 0, fstat(fileFD, &stat) == 0 else {
                    return response
                }
                
                var headers = HTTPHeaders()
                let modified = stat.st_mtimespec.tv_sec
                let size: Int = numericCast(stat.st_size)
                
                // Generate ETag value, "HEX value of last modified date" + "-" + "file size"
                let fileETag = "\(modified)-\(size)"
                headers[.eTag] = fileETag
                headers[.contentLength] = size.description
                
                // Check if file has been cached already and return NotModified response if the etags match
                if fileETag == response.http.headers[.ifNoneMatch] {
                    throw Abort(.notModified)
                }
                
                response.http.headers = headers
                
                // Set Content-Type header based on the media type
                // Only set Content-Type if file not modified and returned above.
                if
                    let fileExtension = path.components(separatedBy: ".").last,
                    let type = MediaType.from(fileExtension: fileExtension)
                {
                    if self.webTypes.contains(type) {
                        response.http.mediaType = type
                    } else {
                        response.http.mediaType = MediaType(type: "application", subtype: "octet-stream")
                    }
                }
                
                response.http.body = HTTPBody(size: size) { writeContext in
                    if writeContext.ssl {
                        fatalError("Unsupported SSL for serving file")
                    } else {
                        // defaults to `0` for send all
                        var sent: off_t = 0
                        
                        let code = sendfile(fileFD, writeContext.descriptor, 0, &sent, nil, 0)
                        
                        guard code == 0 else {
                            throw VaporError(identifier: "file-serve-error", reason: "An error code \(code) occurred trying to serve a file")
                        }
                        
                        return Future(())
                    }
                }
                
                return response
            } else {
                return response
            }
        }
    }
}
