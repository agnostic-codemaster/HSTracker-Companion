//
//  Http.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 11/10/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation
import PromiseKit

struct Http {
    let url: String

    static func transportSummary(data: Data?, response: URLResponse?, error: Error?) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode
        let failure = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "none"
        return "status=\(status.map(String.init) ?? "none"), bytes=\(data?.count ?? 0), error=\(failure)"
    }

    func json(method: HttpMethod,
              parameters: [String: Any] = [:],
              data: Data? = nil,
              headers: [String: String] = [:],
              responseStatus: ((Int?) -> Void)? = nil,
              completion: @escaping (Any?) -> Void) {
        guard let urlRequest = prepareRequest(method: method,
                                              encoding: .json,
                                              data: data,
                                              parameters: parameters,
                                              headers: headers) else {
                                                responseStatus?(nil)
                                                completion(nil)
                                                return
        }

        Http.session.dataTask(with: urlRequest) { data, response, error in
            logger.info("Fetching \(urlRequest.url?.host ?? "unknown host") complete")

            if let error = error {
                logger.error("request error: \(Self.transportSummary(data: data, response: response, error: error))")
                DispatchQueue.main.async {
                    responseStatus?((response as? HTTPURLResponse)?.statusCode)
                    completion(nil)
                }
                return
            } else if let data = data {
                do {
                    let json = try JSONSerialization.jsonObject(with: data,
                                                                options: .allowFragments)
                    DispatchQueue.main.async {
                        responseStatus?((response as? HTTPURLResponse)?.statusCode)
                        completion(json)
                    }
                    return
                } catch let error {
                    logger.error("json parsing : \(error)")
                    DispatchQueue.main.async {
                        responseStatus?((response as? HTTPURLResponse)?.statusCode)
                        completion(nil)
                    }
                }
            } else {
                logger.error("\(#function): \(Self.transportSummary(data: data, response: response, error: error))")
                DispatchQueue.main.async {
                    responseStatus?((response as? HTTPURLResponse)?.statusCode)
                    completion(nil)
                }
            }
            }.resume()
    }
    
    func uploadPromise(method: HttpMethod,
                       headers: [String: String] = [:],
                       data: Data) -> Promise<Any?> {
        return Promise<Any?> { seal in
            guard let urlRequest = prepareRequest(method: method,
                                                  encoding: .multipart,
                                                  parameters: [:],
                                                  headers: headers) else {
                seal.fulfill(nil)
                return
            }

            Http.session.uploadTask(with: urlRequest,
                                    from: data) { data, response, error in
                if let error = error {
                    logger.error("request error: \(Self.transportSummary(data: data, response: response, error: error))")
                    seal.reject(error)
                } else if let data = data {
                    logger.verbose("upload result: \(data.count) bytes")
                    seal.fulfill(data)
                }
                logger.debug("p \(#function): \(Self.transportSummary(data: data, response: response, error: error))")
            }.resume()
        }
    }
    
//    func getAsync(parameters: [String: Any] = [:], headers: [String: String] = [:]) async -> Data? {
//        guard let urlRequest = prepareRequest(method: .get, encoding: .multipart, parameters: parameters, headers: headers) else {
//            return nil
//        }
//        return await withCheckedContinuation { cont in
//            Http.session.dataTask(with: urlRequest) { (data, _, error) in
//                if let error = error {
//                    logger.error("request error: \(error)")
//                    cont.resume(returning: nil)
//                } else if let data = data {
//                    logger.verbose("get result: \(data)")
//                    cont.resume(returning: data)
//                } else {
//                    cont.resume(returning: nil)
//                }
//            }.resume()
//        }
//    }
//    
//    func uploadAsync(method: HttpMethod, data: Data, parameters: [String: Any] = [:], headers: [String: String] = [:]) async -> Data? {
//        guard let urlRequest = prepareRequest(method: method, encoding: .multipart, parameters: parameters, headers: headers) else {
//            return nil
//        }
//        return await withCheckedContinuation { cont in
//            Http.session.uploadTask(with: urlRequest, from: data) { (data, _, error) in
//                if let error = error {
//                    logger.error("request error: \(error)")
//                    cont.resume(returning: nil)
//                } else if let data = data {
//                    logger.verbose("upload result: \(data)")
//                    cont.resume(returning: data)
//                } else {
//                    cont.resume(returning: nil)
//                }
//            }.resume()
//        }
//    }

    func getPromise(method: HttpMethod,
                    headers: [String: String] = [:]) -> Promise<Data?> {
        return Promise<Data?> { seal in
            guard let urlRequest = prepareRequest(method: method,
                                                  encoding: .multipart,
                                                  parameters: [:],
                                                  headers: headers) else {
                seal.fulfill(nil)
                return
            }

            Http.session.dataTask(with: urlRequest) { data, response, error in
                if let error = error {
                    logger.error("request error: \(Self.transportSummary(data: data, response: response, error: error))")
                    seal.reject(error)
                } else if let data = data {
                    logger.verbose("get result: \(data.count) bytes")
                    seal.fulfill(data)
                }
                logger.debug("p \(#function): \(Self.transportSummary(data: data, response: response, error: error))")
            }.resume()
        }
    }

    func upload(method: HttpMethod,
                headers: [String: String] = [:],
                data: Data,
                completion: ((Bool, String?) -> Void)? = nil) {
        guard let urlRequest = prepareRequest(method: method,
                                              encoding: .multipart,
                                              parameters: [:],
                                              headers: headers) else {
                                                completion?(false, "invalid upload URL")
                                                return
        }

        Http.session.uploadTask(with: urlRequest,
                                from: data) { data, response, error in
                                    if let error = error {
                                        logger.error("request error: \(Self.transportSummary(data: data, response: response, error: error))")
                                    } else if let data = data {
                                        logger.verbose("upload result: \(data.count) bytes")
                                    }
                                    
                                    logger.debug("\(#function): \(Self.transportSummary(data: data, response: response, error: error))")
                                    let code = (response as? HTTPURLResponse)?.statusCode
                                    let success = error == nil && code.map { (200..<300).contains($0) } == true
                                    completion?(success, error?.localizedDescription ?? code.map { "HTTP \($0)" })
                                    
            }.resume()
    }

    private func prepareRequest(method: HttpMethod,
                                encoding: HttpEncoding,
                                data: Data? = nil,
                                parameters: [String: Any] = [:],
                                headers: [String: String] = [:]) -> URLRequest? {
        var urlQuery = ""
        if method == .get && parameters.count > 0 {
            urlQuery = "?" + query(parameters: parameters)
        }

        guard let url = URL(string: url + urlQuery) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue.uppercased()

        if encoding == .json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            if method != .get {
                do {
                    if let data {
                        request.httpBody = data
                    } else {
                        let bodyData = try JSONSerialization.data(withJSONObject: parameters,
                                                                  options: .prettyPrinted)
                        request.httpBody = bodyData
                    }
                } catch let error {
                    logger.error("json converting : \(error)")
                    return nil
                }
            }
        }

        for (headerField, headerValue) in headers {
            request.setValue(headerValue, forHTTPHeaderField: headerField)
        }
        
        request.cachePolicy = .reloadRevalidatingCacheData

        return request
    }
}

// MARK: - Code copied from Alamofire
extension Http {
    func query(parameters: [String: Any]) -> String {
        var components: [(String, String)] = []

        for key in parameters.keys.sorted(by: <) {
            let value = parameters[key]!
            components += queryComponents(key, value)
        }

        return (components.map { "\($0)=\($1)" } as [String]).joined(separator: "&")
    }

    private func queryComponents(_ key: String, _ value: Any) -> [(String, String)] {
        var components: [(String, String)] = []

        if let dictionary = value as? [String: Any] {
            for (nestedKey, value) in dictionary {
                components += queryComponents("\(key)[\(nestedKey)]", value)
            }
        } else if let array = value as? [Any] {
            for value in array {
                components += queryComponents("\(key)[]", value)
            }
        } else {
            components.append((escape(key), escape("\(value)")))
        }

        return components
    }

    private func escape(_ string: String) -> String {
        // does not include "?" or "/" due to RFC 3986 - Section 3.4
        let generalDelimitersToEncode = ":#[]@"

        let subDelimitersToEncode = "!$&'()*+,;="

        var allowedCharacterSet = CharacterSet.urlQueryAllowed
        allowedCharacterSet.remove(charactersIn:
            "\(generalDelimitersToEncode)\(subDelimitersToEncode)")

        return string.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet) ?? string

    }

    fileprivate static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = defaultHTTPHeaders
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        }()

    public static func userAgent() -> String {
        if let info = Bundle.main.infoDictionary {
            let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
            _ = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
            let appVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
            let appBuild = info[kCFBundleVersionKey as String] as? String ?? "Unknown"

            let osNameVersion: String = {
                let version = ProcessInfo.processInfo.operatingSystemVersion
                let versionString = "\(version.majorVersion)"
                    + ".\(version.minorVersion)"
                    + ".\(version.patchVersion)"

                return "macOS \(versionString)"
            }()

            return "\(executable)/\(appVersion) (build:\(appBuild); \(osNameVersion))"
        }

        return "HSTracker"
    }
    private static let defaultHTTPHeaders: [String: String] = {
        // Accept-Encoding HTTP Header; see https://tools.ietf.org/html/rfc7230#section-4.2.3
        let acceptEncoding: String = "gzip" //;q=1.0, compress;q=0.5"

        // Accept-Language HTTP Header; see https://tools.ietf.org/html/rfc7231#section-5.3.5
        let acceptLanguage = Locale.preferredLanguages
            .prefix(6).enumerated().map { index, languageCode in
            let quality = 1.0 - (Double(index) * 0.1)
            return "\(languageCode)" //";q=\(quality)"
            }.joined(separator: ", ")

        // User-Agent Header; see https://tools.ietf.org/html/rfc7231#section-5.5.3
        let ua = userAgent()

        return [
            "Accept-Encoding": acceptEncoding,
            "Accept-Language": acceptLanguage,
            "User-Agent": ua
        ]
    }()
}
