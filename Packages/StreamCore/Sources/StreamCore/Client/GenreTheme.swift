import Foundation

public struct GenreTheme: Identifiable, Hashable, Sendable {
    public let title: String
    public let genreID: Int
    public let keyword: String
    public var id: String { "\(genreID):\(keyword)" }

    public static func themes(for genre: String) -> [GenreTheme] {
        let key = genre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let definition: (Int, [(String, String)])
        switch key {
        case "horror": definition = (27, [("Slasher horror", "slasher"), ("Supernatural horror", "supernatural"), ("Psychological horror", "psychological horror"), ("Creature features", "monster"), ("Found footage", "found footage"), ("Folk horror", "folk horror"), ("Body horror", "body horror"), ("Haunted houses", "haunted house"), ("Possession", "possession"), ("Zombies", "zombie"), ("Vampires", "vampire"), ("Werewolves", "werewolf"), ("Horror comedy", "horror comedy")])
        case "action": definition = (28, [("Martial arts", "martial arts"), ("Spy missions", "spy"), ("Revenge", "revenge"), ("Heists", "heist"), ("Superheroes", "superhero"), ("Chases", "chase")])
        case "adventure": definition = (12, [("Treasure hunts", "treasure hunt"), ("Survival", "survival"), ("Pirate adventures", "pirate")])
        case "comedy": definition = (35, [("Dark comedy", "dark comedy"), ("Satire", "satire"), ("Road trips", "road trip"), ("Romantic comedy", "romantic comedy"), ("Slapstick", "slapstick"), ("Parodies", "parody")])
        case "drama": definition = (18, [("Courtroom drama", "courtroom"), ("Coming of age", "coming of age"), ("Family relationships", "family relationships")])
        case "sci-fi", "science fiction", "science-fiction": definition = (878, [("Time travel", "time travel"), ("Alien encounters", "alien"), ("Dystopian futures", "dystopia"), ("Space exploration", "space exploration"), ("Artificial intelligence", "artificial intelligence"), ("Cyberpunk", "cyberpunk")])
        case "fantasy": definition = (14, [("Magic", "magic"), ("Dragons", "dragon"), ("Fairy tales", "fairy tale")])
        case "thriller": definition = (53, [("Psychological thrillers", "psychological thriller"), ("Conspiracies", "conspiracy"), ("Survival thrillers", "survival")])
        case "crime": definition = (80, [("Heists", "heist"), ("Organized crime", "organized crime"), ("Detective stories", "detective")])
        case "mystery": definition = (9648, [("Murder mysteries", "murder mystery"), ("Private detectives", "private detective"), ("Missing persons", "missing person")])
        case "romance": definition = (10749, [("First love", "first love"), ("Second chances", "second chance"), ("Forbidden love", "forbidden love")])
        case "animation": definition = (16, [("Anime", "anime"), ("Stop motion", "stop motion"), ("Animated adventures", "adventure")])
        case "family": definition = (10751, [("Animal friends", "animal"), ("Magic and wonder", "magic"), ("Family adventures", "adventure")])
        case "documentary": definition = (99, [("Nature", "nature"), ("True crime", "true crime"), ("Music documentaries", "music documentary")])
        case "war": definition = (10752, [("World War II", "world war ii"), ("Anti-war stories", "anti war"), ("Naval warfare", "naval warfare")])
        case "western": definition = (37, [("Spaghetti westerns", "spaghetti western"), ("Outlaws", "outlaw"), ("Revenge in the West", "revenge")])
        case "history": definition = (36, [("Ancient Rome", "ancient rome"), ("Royalty", "royalty"), ("Historical biographies", "biography")])
        case "music", "musical": definition = (10402, [("Concert films", "concert film"), ("Rock music", "rock music"), ("Musicals", "musical")])
        default: return []
        }
        return definition.1.map { GenreTheme(title: $0.0, genreID: definition.0, keyword: $0.1) }
    }
}
