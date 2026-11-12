import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Calls [onRestore] whenever the browser shows this page again from its back/forward cache.
void onPageRestoredFromCache(void Function() onRestore) {
  web.window.addEventListener(
    'pageshow',
    ((web.Event event) {
      if ((event as web.PageTransitionEvent).persisted) onRestore();
    }).toJS,
  );
}
