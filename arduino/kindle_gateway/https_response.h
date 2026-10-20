#pragma once

// In un header a parte perché i prototipi generati dall'IDE Arduino finiscono
// prima delle definizioni dello sketch.
struct Response {
  int code = -1;
  bool chunked = false;
  long length = -1;
};
