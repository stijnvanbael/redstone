library redstone.src.response_writer;

import 'dart:async';
import 'dart:convert' as conv;
import 'dart:io';

import 'package:di/di.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:stack_trace/stack_trace.dart';

import 'request.dart';
import 'request_context.dart';
import 'server_metadata.dart';

Future<shelf.Response> writeResponse(String handlerName, dynamic response,
    {int statusCode: 200,
    String responseType,
    Injector injector,
    List<ResponseProcessorMetadata> responseProcessors: const []}) async {
  if (statusCode == null) {
    statusCode = 200;
  }

  if (response is RequestException) {
    return new shelf.Response(response.statusCode,
        body: response.message,
        headers: {"content-type": "text/plain"},
        encoding: conv.UTF8);
  }
  if (response is ErrorResponse) {
    statusCode = response.statusCode;
    response = response.error;
  }

  await Future.forEach(
      responseProcessors,
      (p) async =>
  response =
  await p.processor(p.metadata, handlerName, response, injector));

  if (response == null) {
    return new shelf.Response(statusCode);
  }

  if (response is shelf.Response) {
    return response;
  } else if (response is Map || response is List) {
    var type = responseType != null ? responseType : "application/json";
    return new shelf.Response(statusCode,
        body: conv.JSON.encode(response),
        headers: {"content-type": type},
        encoding: conv.UTF8);
  } else if (response is File) {
    var type =
    responseType != null ? responseType : lookupMimeType(response.path);
    return new shelf.Response(statusCode,
        body: response.openRead(), headers: {"content-type": type});
  } else {
    var type = responseType != null ? responseType : "text/plain";
    return new shelf.Response(statusCode,
        body: response.toString(), headers: {"content-type": type});
  }
}

shelf.Response writeErrorPage(String resource, Object error,
    [StackTrace stack, int statusCode, Map<String, String> headers]) {
  if (error is RequestException) {
    statusCode = error.statusCode;
  }

  String description = _getStatusDescription(statusCode);

  String formattedStack = null;
  if (stack != null) {
    formattedStack = Trace.format(stack);
  }

  String errorTemplate = '''<!DOCTYPE>
<html>
<head>
  <title>Redstone Server - ${description != null ? description : statusCode}</title>
  <style>
    body, html {
      margin: 0px;
      padding: 0px;
      border: 0px;
    }
    .header {
      height:100px;
      background-color: rgba(204, 49, 0, 0.94);
      color:#F8F8F8;
      overflow: hidden;
    }
    .header p {
      font-family:Helvetica,Arial;
      font-size:36px;
      font-weight:bold;
      padding-left:10px;
      line-height: 30px;
    }
    .footer {
      margin-top:50px;
      padding-left:10px;
      height:20px;
      font-family:Helvetica,Arial;
      font-size:12px;
      color:#5E5E5E;
    }
    .content {
      font-family:Helvetica,Arial;
      font-size:18px;
      padding:10px;
    }
    .info {
      border: 1px solid #C3C3C3;
      margin-top: 10px;
      padding-left:10px;
      font-size: 14px;
    }
  </style>
</head>
<body>
  <div class="header" style="">
    <p>$statusCode ${description != null ? " - " + description : ""}</p>
  </div>
  <div class="content">
    <p><b>Resource: </b> $resource</p>

    <div class="info" style="display:${error != null ? "block" : "none"}">
      <pre>$error - ${formattedStack != null ? "\n\n" + formattedStack : ""}</pre>
    </div>
  </div>
  <div class="footer">Redstone Server - 2015 - <a href="https://github.com/redstone-dart">https://github.com/redstone-dart</a></div>
</body>
</html>''';

  return new shelf.Response(statusCode,
      body: errorTemplate,
      headers: {"content-type": "text/html"}
        ..addAll(headers),
      encoding: conv.UTF8);
}

String _getStatusDescription(int statusCode) {
  switch (statusCode) {
    case HttpStatus.BAD_REQUEST:
      return "BAD REQUEST";
    case HttpStatus.NOT_FOUND:
      return "NOT FOUND";
    case HttpStatus.METHOD_NOT_ALLOWED:
      return "METHOD NOT ALLOWED";
    case HttpStatus.INTERNAL_SERVER_ERROR:
      return "INTERNAL SERVER ERROR";
    default:
      return null;
  }
}
