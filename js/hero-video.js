// Home-page banner video: pause/play button, and no autoplay for visitors who
// ask for reduced motion. The button ships hidden so it only appears when this
// script is running to make it work.
document.addEventListener('DOMContentLoaded', function () {
  var video = document.querySelector('.hero-banner__video');
  var toggle = document.querySelector('.hero-banner__toggle');
  if (!video || !toggle) return;

  function sync() {
    toggle.classList.toggle('is-paused', video.paused);
    toggle.setAttribute('aria-label', video.paused ? 'Play video' : 'Pause video');
  }

  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    video.removeAttribute('autoplay');
    video.pause();
  }

  toggle.addEventListener('click', function () {
    if (video.paused) {
      video.play();
    } else {
      video.pause();
    }
  });
  video.addEventListener('play', sync);
  video.addEventListener('pause', sync);

  toggle.hidden = false;
  sync();
});
