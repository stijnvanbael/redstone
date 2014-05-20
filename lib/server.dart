library redstone_server;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';
import 'dart:convert' as conv;
import 'dart:math';

import 'package:shelf/shelf.dart' as shelf;
import 'package:mime/mime.dart';
import 'package:route_hierarchical/url_matcher.dart';
import 'package:route_hierarchical/url_template.dart';
import 'package:logging/logging.dart';
import 'package:crypto/crypto.dart';

import 'package:di/di.dart';
import 'package:di/auto_injector.dart';

part 'package:redstone/src/metadata.dart';
part 'package:redstone/src/logger.dart';
part 'package:redstone/src/exception.dart';
part 'package:redstone/src/setup_impl.dart';
part 'package:redstone/src/plugin_impl.dart';
part 'package:redstone/src/server_impl.dart';
part 'package:redstone/src/blacklist.dart';
part 'package:redstone/src/http_body_parser.dart';

const String GET = "GET";
const String POST = "POST";
const String PUT = "PUT";
const String DELETE = "DELETE";

const String JSON = "json";
const String FORM = "form";
const String TEXT = "text";
const String BINARY = "binary";

const String ROUTE = "ROUTE";
const String INTERCEPTOR = "INTERCEPTOR";
const String ERROR_HANDLER = "ERROR_HANDLER";

const String _DEFAULT_ADDRESS = "0.0.0.0";
const int _DEFAULT_PORT = 8080;

/**
 * The request's information and content.
 */
abstract class Request {
  
  /// The original [Uri] for the request.
  Uri get requestedUri;
  
  /// The remainder of the [requestedUri] path and query designating the virtual
  /// "location" of the request's target within the handler.
  ///
  /// [url] may be an empty, if [requestedUri]targets the handler
  /// root and does not have a trailing slash.
  ///
  /// [url] is never null. If it is not empty, it will start with `/`.
  ///
  /// [scriptName] and [url] combine to create a valid path that should
  /// correspond to the [requestedUri] path.
  Uri get url;

  ///The method, such as 'GET' or 'POST', for the request (read-only).
  String get method;

  ///The query parameters associated with the request
  Map<String, String> get queryParams;

  ///The body type, such as 'JSON', 'TEXT' or 'FORM'
  String get bodyType;
  
  ///Indicate if this request is multipart
  bool get isMultipart;

  /**
   * The request body.
   *
   * [body] can be a [Map], [List] or [String]. See [HttpBody]
   * for more information.
   */ 
  dynamic get body;

  ///The headers of the request
  Map<String, String> get headers;

  ///The session for the given request (read-only).
  HttpSession get session;
  
  /**
   * Map of request attributes.
   * 
   * Attributes are objects that can be shared between
   * interceptors and routes
   */
  Map<String, Object> get attributes;
  
  ///The original Shelf request
  shelf.Request get shelfRequest;

}

/**
 * A request whose body was not fully read yet
 */
abstract class UnparsedRequest extends Request {
  
  void parseBodyType();
  
  Future parseBody();
  
  set shelfRequest(shelf.Request req);
  
}

/**
 * A writer which can serialize a response to the client
 */
abstract class Writer {
  
  Future<HttpResponse> writeResponse(shelf.Response response);
  
}

/**
 * Request handler
 */
abstract class RequestHandler implements UnparsedRequest, Writer {}

/**
 * HttpRequest parser
 */
class HttpRequestParser {
  
  String _bodyType;
  bool _isMultipart = false;
  ContentType _contentType;
  HttpBody _requestBody;
  Future _bodyParsed = null;
  
  String get bodyType => _bodyType;
  bool get isMultipart => _isMultipart;
  get body => _requestBody != null ? _requestBody.body : null;
  
  void parseHttpRequestBodyType(Map<String, String> headers) {
    var ct = headers["content-type"];
    if (ct == null) {
      return;
    }
    _contentType = ContentType.parse(ct);
    if (_contentType == null) {
      return;
    }
    switch (_contentType.primaryType) {
      case "text":
        _bodyType = TEXT;
        break;
      case "application":
        switch (_contentType.subType) {
          case "json":
            _bodyType = JSON;
            break;
          case "x-www-form-urlencoded":
            _bodyType = FORM;
            break;
        }
        break;
      case "multipart":
        _isMultipart = true;
        switch (_contentType.subType) {
          case "form-data":
            _bodyType = FORM;
            break;
        }
        break;
      default:
        _bodyType = "binary";
        break;
    }
  }
  
  Future parseHttpRequestBody(Stream<List<int>> body) {
    if (_bodyParsed != null) {
      return _bodyParsed;
    }
    
    _bodyParsed = _parseRequestBody(body, _contentType).
        then((HttpBody reqBody) {
          _requestBody = reqBody;
          return reqBody.body;
    });
    return _bodyParsed;
  }
}

/**
 * Utility methods to handle shelf objects
 */
class ShelfTransformer {
  
  shelf.Request buildShelfRequest(HttpRequest req) {
    var headers = {};
    req.headers.forEach((k, v) {
      // Multiple header values are joined with commas.
      // See http://tools.ietf.org/html/draft-ietf-httpbis-p1-messaging-21#page-22
      headers[k] = v.join(',');
    });

    return new shelf.Request(req.method, req.requestedUri,
        protocolVersion: req.protocolVersion, headers: headers,
        body: req);
  }
  
  Future writeHttpResponse(shelf.Response response, HttpResponse httpResponse) {
    return _writeHttpResponse(response, httpResponse);
  }
  
}

/**
 * The chain of the given request.
 *
 * A chain is composed of a target and 0 or more interceptors,
 * and it can be directly manipulated only by interceptors.
 */
abstract class Chain {
  
  ///The error object thrown by the target
  dynamic get error;
  
  /**
   * Call the next element of this chain (an interceptor or a target)
   *
   * The given [callback] will be executed when all following elements
   * in the chain are completed. The callback can return a [Future].
   */
  void next([callback()]);

  ///Interrupt this chain. If [statusCode] or [responseValue] is informed,
  ///a new Response will be created. 
  void interrupt({int statusCode, Object responseValue, String responseType});
  
  ///Returns true if this chain was interrupted
  bool get interrupted;

}

/**
 * User credentials from request
 * 
 */
class Credentials {
  
  String username;
  String password;
  
  Credentials(this.username, this.password);

}

/**
 * The request's information and content.
 *
 * Since each request run in it's own [Zone], it's completely safe
 * to access this object at any time, even in async callbacks.
 */
Request get request => Zone.current[#request];

/**
 * The [Response] object, used for sending back the response to the client.
 */
shelf.Response get response => Zone.current[#state].response;

set response(shelf.Response value) => Zone.current[#state].response = value;

/**
 * The request's chain.
 *
 * Since each request run in its own [Zone], it's completely safe
 * to access this object at any time, even in async callbacks.
 */
Chain get chain => Zone.current[#chain];

/**
 * Abort the current request.
 *
 * If there is an ErrorHandler registered to [statusCode], it
 * will be invoked. Otherwise, the default ErrorHandler will be invoked.
 */
void abort(int statusCode) {
  _notifyError(statusCode, request.url.path);
  chain.interrupt();
}

/**
 * Redirect the user to [url].
 *
 * [url] can be absolute, or relative to the url of the current request.
 */
void redirect(String url) {
  chain.interrupt();
  response = new shelf.Response.found(request.url.resolve(url));
}

/**
 * Parse authorization header from request.
 * 
 */
Credentials parseAuthorizationHeader() {
  if (request.headers[HttpHeaders.AUTHORIZATION] != null) {
    String authorization = request.headers[HttpHeaders.AUTHORIZATION];
    List<String> tokens = authorization.split(" ");
    if ("Basic" == tokens[0]) {
      String auth = conv.UTF8.decode(CryptoUtils.base64StringToBytes(tokens[1]));
      int idx = auth.indexOf(":");
      if (idx > 0) {
        String username = auth.substring(0, idx);
        String password = auth.substring(idx + 1);
        return new Credentials(username, password);
      }
    }
  }
  return null;
}

/**
 * Http Basic access authentication
 *
 * Returns true if the current request contains the authorization header for [username] and [password]. 
 * If authentication fails and [realm] is provided, then a new response with 401 status code and
 * a 'www-authenticate' header will be created.
 */
bool authenticateBasic(String username, String password, {String realm}){
  bool r = false;
  var headers = request.headers;
  if (request.headers[HttpHeaders.AUTHORIZATION] != null) {
    String authorization = request.headers[HttpHeaders.AUTHORIZATION];
    List<String> tokens = authorization.split(" ");
    String auth = CryptoUtils.bytesToBase64(conv.UTF8.encode("$username:$password"));
    if ("Basic" == tokens[0] && auth == tokens[1]) {
      r = true;
    }
  }
  if (!r) {
    if (realm != null) {
      Map headers = new Map.from(response.headers);
      headers[HttpHeaders.WWW_AUTHENTICATE] = 'Basic realm="$realm"';
      response = new shelf.Response(HttpStatus.UNAUTHORIZED, 
          body: response.read(), headers: headers);
    }
  }
  
  return r;
}

/**
 * Register a module for dependency injection.
 * 
 * All modules must be registered before invoking the [start] or
 * [setUp] methods.
 */
void addModule(Module module) {
  _modules.add(module);
}

/**
 * Register a plugin.
 * 
 * All plugins must be registered before invoking the [start] or
 * [setUp] methods.
 */
void addPlugin(RedstonePlugin plugin) {
  _plugins.add(plugin);
}

/**
 * Register a Shelf Middleware.
 * 
 * Middlewares are invoked before any interceptor or route. 
 */
void addShelfMiddleware(shelf.Middleware middleware) {
  if (_initHandler == null) {
    _initHandler = new shelf.Pipeline();
  }
  _initHandler = _initHandler.addMiddleware(middleware);
}

/**
 * Register a Shelf Handler.
 * 
 * The [handler] will be invoked when all interceptors are
 * completed, and no route is found for the requested URL.
 */
void setShelfHandler(shelf.Handler handler) {
  _finalHandler = handler;
}

/**
 * Start the server.
 *
 * The [address] can be a [String] or an [InternetAddress].
 */
Future<HttpServer> start({address: _DEFAULT_ADDRESS, int port: _DEFAULT_PORT}) {
  return new Future(() {
    
    setUp();

    return runZoned(() {
      return HttpServer.bind(address, port).then((server) {
        server.listen((HttpRequest req) {

            _logger.fine("Received request for: ${req.uri}");
            _dispatchRequest(new _RequestImpl(req)).then((shelf.Response resp) {
              return _writeHttpResponse(resp, req.response);
            }, onError: (e) {
              shelf.Response resp = new shelf.Response.internalServerError();
              return _writeHttpResponse(resp, req.response);
            }).catchError((e, s) {
              _logger.severe("Failed to handle request for ${req.uri}", e, s);
            });

          });
  
        _logger.info("Running on $address:$port");
        return server;
      });
    }, onError: (e, s) {
      _logger.severe("Failed to handle request", e, s);
    });
  });
}

/**
 * Serve a [Stream] of [HttpRequest]s.
 * 
 * [HttpServer] implements [Stream<HttpRequest>], so it can be passed directly
 * to [serveRequests].
 */
void serveRequests(Stream<HttpRequest> requests) {
  
}

/**
 * Scan and initialize routes, interceptors and error handlers
 * 
 * If [libraries] is provided, then the scan process will be limited
 * to these libraries. This method is intended to be used in unit tests.
 */
void setUp([List<Symbol> libraries]) {
  try {
    _scanHandlers(libraries);
  } catch (e) {
    _handleError("Failed to configure handlers.", e);
    throw e;
  }
}

/**
 * Remove all modules, plugins, routes, interceptors and error handlers.
 * 
 * This method is intended to be used in unit tests.
 */
void tearDown() {
  _clearHandlers();
}

/**
 * Dispatch a request.
 * 
 * This method is intended to be used in unit tests, where you
 * can create new requests with [MockRequest]
 */
Future<HttpResponse> dispatch(RequestHandler request) => 
    _dispatchRequest(request).then((resp) => request.writeResponse(resp));


/**
 * Allows to programmatically create routes, interceptors, error handlers
 * and parameter providers.
 * 
 * To access a [Manager] instance, you need to create and register a [RedstonePlugin].
 */
abstract class Manager {
  
  /**
   * Create a new route.
   */
  void addRoute(Route conf, String name, RouteHandler route, {String bodyType});
  
  /**
   * Create a new interceptor.
   */
  void addInterceptor(Interceptor conf, String name, Handler interceptor);
  
  /**
   * Create a new error handler.
   */
  void addErrorHandler(ErrorHandler conf, String name, Handler errorHandler);
  
  /**
   * Create a new parameter provider.
   * 
   * [metadataType] is the annotation type that triggers this provider. 
   * [parameterProvider] is the function which will be invoked to create
   * the parameter's value. [handlerTypes] are the handler types that can use
   * this provider, and defaults to ROUTE.
   */
  void addParameterProvider(Type metadataType, ParamProvider parameterProvider, 
                            {List<String> handlerTypes: const [ROUTE]});
  
  /**
   * Create a new response processor.
   * 
   * [metadataType] is the annotation type that triggers this processor.
   * [processor] is the function which will be invoked to transform the returned
   * value. 
   */
  void addResponseProcessor(Type metadataType, ResponseProcessor processor);
  
}

/**
 * A plugin is a function which can dynamically add new features
 * to an application.
 */
typedef void RedstonePlugin(Manager manager);

/**
 * A route programmatically created by a plugin.
 */
typedef dynamic RouteHandler(Map<String, String> pathSegments, 
                             Injector injector, Request request);

/**
 * An interceptor or error handler, programmatically created by a plugin.
 */
typedef dynamic Handler(Injector injector);

/**
 * A parameter provider is a function that can create parameters
 * for routes, interceptors and error handlers.
 * 
 * It can be used, for example, to automatically validate
 * and parse the request's body and arguments.
 */
typedef Object ParamProvider(dynamic metadata, Type paramType, 
                             String handlerName, String paramName, 
                             Request request, Injector injector);

/**
 * A response processor is a function, that can transform values
 * returned by routes.
 */
typedef Object ResponseProcessor(dynamic metadata, String handlerName, 
                                 Object response, Injector injector);
