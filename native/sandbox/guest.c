#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#define IMPORT(name) __attribute__((import_module("host"), import_name(name)))
#define EXPORT(name) __attribute__((export_name(name)))

IMPORT("call") extern int32_t host_call(const char *op, int32_t op_len, const char *req, int32_t req_len);
IMPORT("take") extern void host_take(char *dst);

static JSRuntime *rt;
static JSContext *ctx;
static char *result;
static size_t result_len;

static JSValue js_host(JSContext *c, JSValueConst this_val, int argc, JSValueConst *argv) {
  size_t op_len, req_len;
  if (argc < 2) return JS_ThrowTypeError(c, "__host(op, payload)");
  const char *op = JS_ToCStringLen(c, &op_len, argv[0]);
  if (!op) return JS_EXCEPTION;
  const char *req = JS_ToCStringLen(c, &req_len, argv[1]);
  if (!req) {
    JS_FreeCString(c, op);
    return JS_EXCEPTION;
  }
  int32_t n = host_call(op, (int32_t)op_len, req, (int32_t)req_len);
  JS_FreeCString(c, op);
  JS_FreeCString(c, req);

  int failed = n < 0;
  size_t len = failed ? (size_t)(-(n + 1)) : (size_t)n;
  char *buf = js_malloc(c, len + 1);
  if (!buf) return JS_EXCEPTION;
  host_take(buf);
  JSValue text = JS_NewStringLen(c, buf, len);
  js_free(c, buf);
  if (JS_IsException(text)) return text;
  if (!failed) return text;

  JSValue error = JS_NewError(c);
  JS_DefinePropertyValueStr(c, error, "message", text, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
  return JS_Throw(c, error);
}

static void set_result(JSValueConst value) {
  size_t len;
  const char *text = JS_ToCStringLen(ctx, &len, value);
  free(result);
  result = NULL;
  result_len = 0;
  if (!text) return;
  result = malloc(len + 1);
  if (result) {
    memcpy(result, text, len);
    result_len = len;
  }
  JS_FreeCString(ctx, text);
}

EXPORT("sb_alloc") void *sb_alloc(int32_t len) { return malloc((size_t)len + 1); }

EXPORT("sb_free") void sb_free(void *ptr) { free(ptr); }

EXPORT("sb_init") int32_t sb_init(int32_t memory_limit, int32_t stack_limit) {
  rt = JS_NewRuntime();
  if (!rt) return 1;
  if (memory_limit > 0) JS_SetMemoryLimit(rt, (size_t)memory_limit);
  if (stack_limit > 0) JS_SetMaxStackSize(rt, (size_t)stack_limit);
  ctx = JS_NewContext(rt);
  if (!ctx) return 2;
  JSValue global = JS_GetGlobalObject(ctx);
  JS_SetPropertyStr(ctx, global, "__host", JS_NewCFunction(ctx, js_host, "__host", 2));
  JS_FreeValue(ctx, global);
  return 0;
}

EXPORT("sb_eval") int32_t sb_eval(char *source, int32_t len) {
  source[len] = 0;
  JS_UpdateStackTop(rt);
  JSValue value = JS_Eval(ctx, source, (size_t)len, "source.js", JS_EVAL_TYPE_GLOBAL);
  int failed = JS_IsException(value);

  while (!failed) {
    JSContext *job_ctx;
    int ran = JS_ExecutePendingJob(rt, &job_ctx);
    if (ran == 0) break;
    if (ran < 0) failed = 1;
  }

  if (failed) {
    JS_FreeValue(ctx, value);
    JSValue error = JS_GetException(ctx);
    JSValue stack = JS_GetPropertyStr(ctx, error, "stack");
    JSValue text = JS_ToString(ctx, error);
    if (JS_IsString(stack) && JS_IsString(text)) {
      JSValue newline = JS_NewString(ctx, "\n");
      JSValue args[2] = {newline, stack};
      JSValue concat = JS_GetPropertyStr(ctx, text, "concat");
      JSValue joined = JS_Call(ctx, concat, text, 2, args);
      set_result(JS_IsException(joined) ? text : joined);
      JS_FreeValue(ctx, joined);
      JS_FreeValue(ctx, concat);
      JS_FreeValue(ctx, newline);
    } else {
      set_result(text);
    }
    JS_FreeValue(ctx, text);
    JS_FreeValue(ctx, stack);
    JS_FreeValue(ctx, error);
    return 1;
  }

  set_result(value);
  JS_FreeValue(ctx, value);
  return 0;
}

EXPORT("sb_result_ptr") char *sb_result_ptr(void) { return result; }

EXPORT("sb_result_len") int32_t sb_result_len(void) { return (int32_t)result_len; }

EXPORT("sb_heap_used") int32_t sb_heap_used(void) {
  JSMemoryUsage usage;
  JS_ComputeMemoryUsage(rt, &usage);
  return (int32_t)usage.malloc_size;
}
