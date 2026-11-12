/// Never calls [onRestore]: outside a browser there is no back/forward cache.
void onPageRestoredFromCache(void Function() onRestore) {}
