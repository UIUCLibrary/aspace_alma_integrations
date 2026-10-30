function AlmaIntegrations($alma_integrations_form) {
  this.$alma_integrations_form = $alma_integrations_form;
  this.setup_form();
}

AlmaIntegrations.prototype.setup_form = function() {
  var self = this;
  $(document).trigger("loadedrecordsubforms.aspace", this.$alma_integrations_form);
};

$(document).ready(function() {
  var almaIntegrations = new AlmaIntegrations($("#alma_integrations_form"));
});

// The side-by-side MARC comparison.
//
// Both the plain XML view and the marked-up difference view are rendered by the
// server, so the toggle is a class flip: no request, no re-reading of the two
// records, and the XML that gets posted to Alma is never rebuilt from the
// highlighted markup.
function AlmaMarcCompare(container) {
  this.container = container;
  this.toggle = container.querySelector("[data-alma-diff-toggle]");
  this.filter = container.querySelector("[data-alma-diff-filter]");
  this.setup();
}

AlmaMarcCompare.prototype.setup = function() {
  var self = this;

  if (this.toggle) {
    this.toggle.addEventListener("click", function(event) {
      event.preventDefault();
      self.setShowing(!self.isShowing());
    });
  }

  if (this.filter) {
    this.filter.addEventListener("change", function() {
      self.container.classList.toggle("alma-diff-only", self.filter.checked);
    });
  }
};

AlmaMarcCompare.prototype.isShowing = function() {
  return this.container.classList.contains("alma-diff-on");
};

AlmaMarcCompare.prototype.setShowing = function(showing) {
  this.container.classList.toggle("alma-diff-on", showing);

  if (this.toggle) {
    this.toggle.setAttribute("aria-pressed", showing ? "true" : "false");
  }
};

$(document).ready(function() {
  var containers = document.querySelectorAll("[data-alma-marc-compare]");

  for (var i = 0; i < containers.length; i++) {
    new AlmaMarcCompare(containers[i]);
  }
});
