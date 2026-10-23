import Foundation

/// Default objects for a new collection, matching what Anki itself
/// writes in schema 11 form.
enum Defaults {
    static let latexPre = """
        \\documentclass[12pt]{article}
        \\special{papersize=3in,5in}
        \\usepackage[utf8]{inputenc}
        \\usepackage{amssymb,amsmath}
        \\pagestyle{empty}
        \\setlength{\\parindent}{0in}
        \\begin{document}

        """
    static let latexPost = "\\end{document}"

    static let css = """
        .card {
            font-family: arial;
            font-size: 20px;
            line-height: 1.5;
            text-align: center;
            color: black;
            background-color: white;
        }

        """

    static let clozeCSS = css + """
        .cloze {
            font-weight: bold;
            color: blue;
        }
        .nightMode .cloze {
            color: lightblue;
        }

        """

    static func conf(creationOffset: Int) -> JSON {
        [
            "activeDecks": [1],
            "curDeck": 1,
            "newSpread": 0,
            "collapseTime": 1200,
            "timeLim": 0,
            "estTimes": true,
            "dueCounts": true,
            "curModel": nil,
            "nextPos": 1,
            "sortType": "noteFld",
            "sortBackwards": false,
            "addToCur": true,
            "dayLearnFirst": false,
            "schedVer": 2,
            "creationOffset": JSON(creationOffset),
            "sched2021": true,
        ]
    }

    static func deck(id: Int64, name: String, conf: Int64 = 1) -> JSON {
        [
            "id": .int(id),
            "mod": .int(Time.nowSecs),
            "name": .string(name),
            "usn": -1,
            "lrnToday": [0, 0],
            "revToday": [0, 0],
            "newToday": [0, 0],
            "timeToday": [0, 0],
            "collapsed": false,
            "browserCollapsed": false,
            "desc": "",
            "dyn": 0,
            "conf": .int(conf),
            "extendNew": 0,
            "extendRev": 0,
            "reviewLimit": nil,
            "newLimit": nil,
            "reviewLimitToday": nil,
            "newLimitToday": nil,
        ]
    }

    static func deckConfig(id: Int64, name: String) -> JSON {
        [
            "id": .int(id),
            "mod": .int(Time.nowSecs),
            "name": .string(name),
            "usn": -1,
            "maxTaken": 60,
            "autoplay": true,
            "timer": 0,
            "replayq": true,
            "new": [
                "bury": false,
                "delays": [1.0, 10.0],
                "initialFactor": 2500,
                "ints": [1, 4, 0],
                "order": 1,
                "perDay": 20,
            ],
            "rev": [
                "bury": false,
                "ease4": 1.3,
                "ivlFct": 1.0,
                "maxIvl": 36500,
                "perDay": 200,
                "hardFactor": 1.2,
            ],
            "lapse": [
                "delays": [10.0],
                "leechAction": 1,
                "leechFails": 8,
                "minInt": 1,
                "mult": 0.0,
            ],
            "dyn": false,
            "newMix": 0,
            "newPerDayMinimum": 0,
            "interdayLearningMix": 0,
            "reviewOrder": 0,
            "newSortOrder": 0,
            "newGatherPriority": 0,
            "buryInterdayLearning": false,
            "fsrsWeights": [],
            "fsrsParams5": [],
            "fsrsParams6": [],
            "desiredRetention": 0.9,
            "ignoreRevlogsBeforeDate": "",
            "easyDaysPercentages": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            "stopTimerOnAnswer": false,
            "secondsToShowQuestion": 0.0,
            "secondsToShowAnswer": 0.0,
            "questionAction": 0,
            "answerAction": 0,
            "waitForAudio": true,
            "sm2Retention": 0.9,
            "weightSearch": "",
        ]
    }

    static func field(_ name: String, ord: Int) -> JSON {
        [
            "name": .string(name),
            "ord": JSON(ord),
            "sticky": false,
            "rtl": false,
            "font": "Arial",
            "size": 20,
            "description": "",
            "plainText": false,
            "collapsed": false,
            "excludeFromSearch": false,
            "id": .int(Int64.random(in: 1...Int64.max)),
            "tag": nil,
            "preventDeletion": false,
        ]
    }

    static func template(_ name: String, ord: Int, qfmt: String, afmt: String) -> JSON {
        [
            "name": .string(name),
            "ord": JSON(ord),
            "qfmt": .string(qfmt),
            "afmt": .string(afmt),
            "bqfmt": "",
            "bafmt": "",
            "did": nil,
            "bfont": "",
            "bsize": 0,
            "id": .int(Int64.random(in: 1...Int64.max)),
        ]
    }

    static func notetype(id: Int64, name: String, cloze: Bool, fields: [String], templates: [(String, String, String)]) -> JSON {
        var reqs: [JSON] = []
        for (ord, t) in templates.enumerated() {
            let used = fields.indices.filter { t.1.contains("{{\(fields[$0])}}") }
            reqs.append([JSON(ord), "any", .array(used.map { JSON($0) })])
        }
        return [
            "id": .int(id),
            "name": .string(name),
            "type": cloze ? 1 : 0,
            "mod": .int(Time.nowSecs),
            "usn": -1,
            "sortf": 0,
            "did": nil,
            "tmpls": .array(templates.enumerated().map { template($1.0, ord: $0, qfmt: $1.1, afmt: $1.2) }),
            "flds": .array(fields.enumerated().map { field($1, ord: $0) }),
            "css": .string(cloze ? clozeCSS : css),
            "latexPre": .string(latexPre),
            "latexPost": .string(latexPost),
            "latexsvg": false,
            "req": cloze ? [] : .array(reqs),
        ]
    }

    static let basicBack = "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}"

    static func stockNotetypes(startID: Int64) -> [JSON] {
        [
            notetype(id: startID, name: "Basic", cloze: false, fields: ["Front", "Back"],
                     templates: [("Card 1", "{{Front}}", basicBack)]),
            notetype(id: startID + 1, name: "Basic (and reversed card)", cloze: false, fields: ["Front", "Back"],
                     templates: [("Card 1", "{{Front}}", basicBack),
                                 ("Card 2", "{{Back}}", "{{FrontSide}}\n\n<hr id=answer>\n\n{{Front}}")]),
            notetype(id: startID + 2, name: "Basic (optional reversed card)", cloze: false,
                     fields: ["Front", "Back", "Add Reverse"],
                     templates: [("Card 1", "{{Front}}", basicBack),
                                 ("Card 2", "{{#Add Reverse}}{{Back}}{{/Add Reverse}}",
                                  "{{FrontSide}}\n\n<hr id=answer>\n\n{{Front}}")]),
            notetype(id: startID + 3, name: "Basic (type in the answer)", cloze: false, fields: ["Front", "Back"],
                     templates: [("Card 1", "{{Front}}\n\n{{type:Back}}", "{{Front}}\n\n<hr id=answer>\n\n{{type:Back}}")]),
            notetype(id: startID + 4, name: "Cloze", cloze: true, fields: ["Text", "Back Extra"],
                     templates: [("Cloze", "{{cloze:Text}}", "{{cloze:Text}}<br>\n{{Back Extra}}")]),
        ]
    }
}
