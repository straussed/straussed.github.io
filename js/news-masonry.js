/* Masonry layout for the news feed.
 *
 * Neither CSS mode gets this right on its own. `columns: 2` packs tightly but
 * fills column by column, so the second-newest photo lands underneath the
 * newest instead of beside it and the feed reads as unsorted. A two-column grid
 * keeps the reading order but makes every row as tall as its tallest photo,
 * which leaves big gaps once portrait and landscape photos are mixed.
 * `grid-template-rows: masonry` would solve it but is not shipping yet.
 *
 * So we place the figures ourselves: walk them newest-first and drop each into
 * whichever column is currently shortest. Newest stays top-left, nothing is
 * cropped, and no gaps open up.
 *
 * Without JavaScript the figures just stack in one column — taller, but in the
 * right order.
 */
(function () {
  var BREAKPOINT = 700; /* keep in sync with css/style.css */

  var gallery = document.querySelector('.news-gallery');
  if (!gallery) return;

  var items = Array.prototype.slice.call(gallery.querySelectorAll('.news-photo'));
  if (items.length < 2) return;

  function layout() {
    var count = window.innerWidth > BREAKPOINT ? 2 : 1;

    /* Always rebuild from the saved list rather than from the current DOM, so
       the source order survives any number of relayouts. */
    var old = gallery.querySelectorAll('.news-column');
    for (var i = 0; i < old.length; i++) old[i].parentNode.removeChild(old[i]);

    if (count === 1) {
      gallery.classList.remove('news-gallery--columns');
      items.forEach(function (item) { gallery.appendChild(item); });
      return;
    }

    var columns = [];
    for (var c = 0; c < count; c++) {
      var col = document.createElement('div');
      col.className = 'news-column';
      gallery.appendChild(col);
      columns.push(col);
    }
    gallery.classList.add('news-gallery--columns');

    /* Height is read back after each append, so "shortest" reflects the real
       laid-out height including the caption, not an estimate from the photo. */
    items.forEach(function (item) {
      var shortest = columns[0];
      for (var c = 1; c < columns.length; c++) {
        if (columns[c].offsetHeight < shortest.offsetHeight) shortest = columns[c];
      }
      shortest.appendChild(item);
    });
  }

  layout();

  /* The width/height attributes on each <img> mean heights are known before the
     photos arrive, but webfonts can still reflow the captions, so balance again
     once everything has settled. */
  window.addEventListener('load', layout);

  var pending;
  window.addEventListener('resize', function () {
    clearTimeout(pending);
    pending = setTimeout(layout, 150);
  });
})();
