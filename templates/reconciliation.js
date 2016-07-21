_.templateSettings = {
  evaluate: /\{\%(.+?)\%\}/g,
  interpolate: /\{\{(.+?)\}\}/g,
  escape: /\{-(.+?)-\}/g
}

var renderTemplate = function renderTemplate(templateName, data){
  data = data || {};
  var source = $('#' + templateName);
  if(source.length){
    return _.template(source.html())(data);
  } else {
    throw 'renderTemplate Error: Could not find source template with matching #' + templateName;
  }
}

var vote = function vote($choice){
  var $pairing = $choice.parents('.pairing');
  var incomingPersonID = $('.pairing__incoming .person', $pairing).attr('data-id');
  var vote = [];

  if($choice.is('.skip')) {
    // Insert a null value to indicate skip.
    // These are removed when serializing to CSV.
    window.votes.push( [incomingPersonID, null] );
  } else if ($choice.is('.show-later')) {
    nextPairing($pairing);
    $pairing.appendTo('.pairings');
    return;
  } else {
    window.votes.push( [incomingPersonID, $choice.attr('data-uuid')] );
  }

  redrawTop();
  nextPairing($pairing);
}

// This function looks through allVotes() to see if there are any IDs
// matched with multiple UUIDs, if typeOfID is 'ID', or vice versa if
// typeOfID is 'UUID'. It then returns an object mapping between each
// ID / UUID and the multiple UUIDs / IDs they've been matched with.
// For example:
//
//   > getDuplicateIDs('ID')
//   {
//     'Q7368324': [
//       "be9c1984-6f08-4a97-8ea6-e82af4daf909",
//       "0c9cf09f-a09c-47f9-a641-6d0dbb23110c"
//     ]
//   }
var getDuplicateIDs = function(typeOfID) {
  var voteColumn = {'ID': 0, 'UUID': 1}[typeOfID],
  votes = allVotes(),
  // Filter out any votes that were skipped, which is those where the
  // second element of the array representing the vote is null.
  votesNotSkipped = _.filter(votes, function (v) { return v[1] !== null });
  duplicated = _.omit(
    _.groupBy(votesNotSkipped, function(e) { return e[voteColumn] }),
    function(v, k, o) { return v.length <= 1 }
  );
  return _.object(
    _.map(duplicated, function(v, k) {
      return [k, _.map(v, function (e) { return e[1 - voteColumn] })]
    })
  );
}

// Render to HTML a warning about one type of duplicate IDs or UUIDs:
var renderDuplicatesTemplate = function(duplicatedIDs, typeOfID) {
  var result = '', n = Object.keys(duplicatedIDs).length;
  if (n) {
    result += renderTemplate('duplicateIDs', {
      duplicates: duplicatedIDs,
      groupedByType: typeOfID,
      otherType: typeOfID == 'ID' ? 'UUID' : 'ID'
    });
  }
  return result;
}

// This function returns HTML that warns about any IDs matched to
// multiple UUIDs or UUIDs matched to multiple IDs:
var renderAllDuplicatesTemplate = function() {
  var result = '';
  ['ID', 'UUID'].forEach(function (typeOfID) {
    result += renderDuplicatesTemplate(getDuplicateIDs(typeOfID), typeOfID);
  });
  if (result) {
    return '<div class="all-duplicates">' + result + '</div>';
  }
  return '';
}

var nextPairing = function nextPairing($currentPairing){
  $currentPairing.hide();
  var $nextPairing = $currentPairing.next();
  if($nextPairing.length){
    highlightExistingVotes($nextPairing);
    $nextPairing.show();
  } else {
    $('.messages').html('<h1>Reconciliation complete!</h1>');
    showCSVtray();
  }
}

var highlightExistingVotes = function highlightExistingVotes($pairing){
  var allVotesSoFar = allVotes();

  $('.pairing__choices .person', $pairing).each(function(){
    $(this).children('.person__already-matched').remove();

    var uuid = $(this).attr('data-uuid');
    var personAlreadyMatched = _.findWhere(allVotesSoFar, {1: uuid});

    if(personAlreadyMatched){
      // This suggested person has already been matched to an incoming person!
      // Chances are, you won't want to match again. If you do, it'll be because
      // the original match was incorrect. So we make this clear in the UI.

      // Get the details for the person they were matched to.
      var priorMatchDetails;
      _.each(window.toReconcile, function(match){
        if(match.incoming.id == personAlreadyMatched[0]){
          priorMatchDetails = match.incoming;
        }
      });

      // Show a warning.
      var warningHTML = renderTemplate('personAlreadyMatched', {
        person: priorMatchDetails ? priorMatchDetails[window.existingField] : personAlreadyMatched[0]
      });
      $(this).prepend(warningHTML);
    }
  });
}

var redrawTop = function redrawTop(){
  updateProgressBar();
  updateUndoButton();
  updateCSVtray();
  $('.messages').text('');
}

var progressAsPercentage = function progressAsPercentage(){
  if (window.toReconcile.length == 0) { return '100%' }
  return '' + (window.votes.length / $('.pairing').length * 100) + '%';
}

var updateProgressBar = function updateProgressBar(){
  $('.progress .progress-bar div').animate({ width: progressAsPercentage() }, 100);
}

var allVotes = function allVotes() {
  return window.reconciled.concat(window.votes).concat(window.autovotes)
}

var votesAsCSV = function votesAsCSV(){
  return Papa.unparse({
    fields: ['id', 'uuid'],
    data: _.sortBy( _.reject(allVotes(), { 1: null }), 1 )
  });
}

var updateCSVtray = function updateCSVtray(){
  $('.csv').val(votesAsCSV());
}

var showCSVtray = function showCSVtray(){
  updateCSVtray();
  $('.export-csv').text('Hide CSV');
  $('.csv').slideDown(100, function(){
    $(this).select();
  });
  $('.messages').append(renderAllDuplicatesTemplate());
}

var hideCSVtray = function hideCSVtray(){
  $('.export-csv').text('Show CSV');
  $('.csv').slideUp(100);
  $('.messages').html('');
}

var toggleCSVtray = function toggleCSVtray(){
  if($('.csv').is(':visible')){
    hideCSVtray();
  } else {
    showCSVtray();
  }
}

var undo = function undo(){
  // Only continue if there's actually something to undo.
  if(window.votes.length == 0){ return; }

  // Remove last vote from window.votes,
  // and re-show the most recently hidden pairing.
  var undoneVote = window.votes.pop();
  if ($('.pairing:visible').length) {
    $('.pairing:visible').hide().prev().show();
  } else {
    $('.pairing').last().show();
    hideCSVtray();
  }
  redrawTop();
}

var updateUndoButton = function updateUndoButton(){
  if(window.votes.length == 0){
    $('.undo').addClass('disabled');
  } else {
    $('.undo').removeClass('disabled');
  }
}

var handleKeyPress = function handleKeyPress(e){
  // Escape
  if(e.keyCode == 27){ return toggleCSVtray(); }

  // Command-Z
  if(e.keyCode == 90 && (e.metaKey || e.ctrlKey)) { return undo(); }

  // Only if there is at least one pairing left to categorise
  if($('.pairing:visible').length && $('.csv').is(':hidden')){
    // right arrow
    if(e.which == 39){ return vote($('.pairing:visible .skip')); }

    // question mark
    if(e.which == 191){ return vote($('.pairing:visible .show-later')); }

    // number key
    if(e.which > 48 && e.which < 58){
      // Avoid votes for numbers that don't exist on the page
      var $choice = $('.pairing:visible .pairing__choices .person').eq(e.which - 49);
      if($choice.length){ vote($choice); }
    }
  }
}

jQuery(function($) {

  $.each(toReconcile, function(i, match) {
    var incomingPerson = match.incoming;

    // If there's one and only one 100% match, choose it automatically
    // var exactMatches  = _.filter(match.existing, function(e) { 
      // return e[1] == 1;
    // });
    // if (exactMatches.length == 1) { 
      // window.autovotes.push( [incomingPerson.id, exactMatches[0][0].uuid] );
      // return;
    // }
    
    var alwaysInclude = ['image', 'twitter'];

    var incomingPersonFields = _.filter(Object.keys(incomingPerson), function(field) {
      return incomingPerson[field];
    });
    var existingPeopleFields = _.uniq(_.flatten(match.existing.map(function(existing) {
      var person = existing[0];
      return Object.keys(person);
    })));
    var commonFields = _.union(alwaysInclude, _.intersection(incomingPersonFields, existingPeopleFields));

    var incomingPersonHTML = renderTemplate('incomingPerson', {
      person: incomingPerson,
      h1_name: incomingPerson[window.incomingField],
      fields: commonFields,
      names: _.uniq(_.map(_.filter(incomingPersonFields, function(f) { return f.includes('name__') }), function(f) { return incomingPerson[f] })).sort()
    });

    var existingPersonHTML = _.map(match.existing, function(existing) {
      var person = existing[0];
      person.matchStrength = Math.ceil(existing[1] * 100);
      var fields = _.union(alwaysInclude, _.intersection(incomingPersonFields, Object.keys(person)));

      var incomingNameWords = incomingPerson[window.incomingField].toLowerCase().replace(',', '').split(/\s+/);
      var markedName = _.map(person[window.existingField].replace(',', '').split(/\s+/), function(word){
        if (_.contains(incomingNameWords, word.toLowerCase())) {
          return '<span class="match">' + word + '</span>'
        } else {
          return word
        }
      }).join(" ");

      return renderTemplate('existingPerson', {
        person: person,
        h1_name: markedName,
        compare_with: incomingPerson,
        fields: fields
      });
    });

    $('.pairings').append(
      renderTemplate('pairing', {
        incomingPersonHTML: incomingPersonHTML,
        existingPersonHTML: existingPersonHTML.join("\n")
      })
    );

  });

  $(document).on('click', '.pairing__choices > div header.person__meta', function(){
    vote($(this).parent());
  });

  $(document).on('keydown', handleKeyPress);

  $('.undo').on('click', function(){
    undo();
  });

  $('.export-csv').on('click', function(e){
    e.stopPropagation();
    toggleCSVtray();
  });

  $('.csv').on('click', function(e){
    e.stopPropagation();
  }).on('focus', function(){
    $(this).select();
  });

  $firstPairing = $('.pairing').first();
  if ($firstPairing.length) {
    $firstPairing.nextAll().hide();
    highlightExistingVotes($firstPairing);
    redrawTop();
  } else {
    $('.messages').append('<h1>Nothing to reconcile!</h1>');
  }

});
