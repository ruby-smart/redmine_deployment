/* The deploy status of an issue (its page, the issue list, the SCRUM taskboard): a click on the indicator or the
   badge opens the whole pipeline as a popup - what every step means and which ones the issue has reached. It
   replaces the tooltip those carried.

   There is one popup for the whole page and it is filled when it is asked for (data-url): a board with 70 cards
   would carry the markup 70 times over otherwise, and a popup inside a scrolling list would be cut off by it. */
(function ($) {
  'use strict';

  var GAP = 6;
  var $popup = null;
  var $current = null;
  // the pipelines already loaded on this page, by issue (a second look needs no second request)
  var loaded = {};

  function popup() {
    if (!$popup) { $popup = $('<div class="deploy-popup deploy-popup-float"></div>').appendTo('body'); }
    return $popup;
  }

  function close() {
    if ($current) { $current.attr('aria-expanded', 'false'); $current = null; }
    if ($popup) { $popup.hide(); }
  }

  // below the status, its right edge aligned with it - above it, if there is no room below
  function place($toggle) {
    var rect = $toggle[0].getBoundingClientRect();
    var $box = popup();
    var width = $box.outerWidth();
    var height = $box.outerHeight();
    var left = Math.min(Math.max(8, rect.right - width), $(window).width() - width - 8);
    var top = rect.bottom + GAP;

    if (top + height > $(window).height() - 8 && rect.top - height - GAP > 8) { top = rect.top - height - GAP; }
    $box.css({ left: Math.round(left) + 'px', top: Math.round(top) + 'px' });
  }

  function show($toggle, html) {
    // the user may have moved on while it was loading
    if (!$current || $current[0] !== $toggle[0]) { return; }

    popup().html(html).show();
    place($toggle);
  }

  function open($toggle) {
    var url = $toggle.attr('data-url');
    if (!url) { return; }

    $current = $toggle;
    $toggle.attr('aria-expanded', 'true');

    if (loaded[url]) { show($toggle, loaded[url]); return; }

    popup().html('').show();
    place($toggle);
    $.ajax({
      url: url,
      type: 'GET',
      dataType: 'html',
      success: function (html) { loaded[url] = html; show($toggle, html); },
      error: function () { close(); }
    });
  }

  $(function () {
    $(document).on('click', '.deploy-status-toggle', function (event) {
      var $toggle = $(this);
      var open_it = !$current || $current[0] !== $toggle[0];

      event.preventDefault();
      event.stopPropagation();
      close();
      if (open_it) { open($toggle); }
    });

    // a click inside the popup keeps it open (selecting text), everywhere else closes it
    $(document).on('click', '.deploy-popup', function (event) { event.stopPropagation(); });
    $(document).on('click', close);
    $(document).on('keydown', function (event) { if (event.keyCode === 27) { close(); } });
    // it belongs to the status it was opened at: scrolling (a list, the page) and resizing let it go
    window.addEventListener('scroll', close, true);
    $(window).on('resize', close);
  });
})(jQuery);
